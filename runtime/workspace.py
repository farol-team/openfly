"""Portable workspace snapshots. Never extract a guest tar with extractall()."""

import gzip
import hashlib
import io
import os
import shutil
import stat
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

MAX_BYTES = 256 * 1024 * 1024
MAX_ENTRIES = 100_000
MAX_TAR_BYTES = MAX_BYTES + 64 * 1024 * 1024


def pack(root):
    total, entries = 0, 0
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            entry = (Path(directory) / name).lstat()
            if not (
                stat.S_ISREG(entry.st_mode)
                or stat.S_ISDIR(entry.st_mode)
                or stat.S_ISLNK(entry.st_mode)
            ):
                raise ValueError("Unsupported workspace entry")
            total += entry.st_size if stat.S_ISREG(entry.st_mode) else 0
            entries += 1
            if total > MAX_BYTES or entries > MAX_ENTRIES:
                raise ValueError("Workspace exceeds size limit")
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz", dereference=False) as archive:
        for path in sorted(Path(root).iterdir()):
            archive.add(path, arcname=path.name)
    data = out.getvalue()
    if len(data) > MAX_BYTES:
        raise ValueError("Workspace archive exceeds limit")
    # Validate our own input, too: do not send links to files outside a project.
    with tempfile.TemporaryDirectory() as directory:
        unpack(data, directory)
    return data


def unpack(data, destination):
    if len(data) > MAX_BYTES:
        raise ValueError("Workspace archive exceeds limit")
    root = Path(destination)
    if root.is_symlink() or not root.is_dir() or any(root.iterdir()):
        raise ValueError("Extraction requires an empty, non-symlink directory")
    # Bound headers, PAX metadata and padding too, not just member file sizes.
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
        expanded = compressed.read(MAX_TAR_BYTES + 1)
    if len(expanded) > MAX_TAR_BYTES:
        raise ValueError("Expanded archive exceeds size limit")
    with tarfile.open(fileobj=io.BytesIO(expanded), mode="r:") as archive:
        members, names, total = [], set(), 0
        for member in archive:
            path = PurePosixPath(member.name)
            if (
                path.is_absolute()
                or not path.parts
                or ".." in path.parts
                or str(path) in names
            ):
                raise ValueError("Unsafe or duplicate archive path")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError("Unsupported archive entry")
            names.add(str(path))
            total += member.size
            if total > MAX_BYTES or len(names) > MAX_ENTRIES:
                raise ValueError("Expanded workspace exceeds limit")
            members.append(member)
        links = {str(PurePosixPath(m.name)) for m in members if m.issym()}
        for member in members:
            path = PurePosixPath(member.name)
            if any(str(parent) in links for parent in path.parents):
                raise ValueError("Archive path traverses a symlink")
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.issym():
                link = member.linkname
                resolved = os.path.abspath(target.parent / link)
                if os.path.isabs(link) or not resolved.startswith(
                    str(root.resolve()) + os.sep
                ):
                    raise ValueError("Symlink leaves workspace")
                target.symlink_to(link)
            elif member.isdir():
                target.mkdir(exist_ok=True)
            else:
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(
                    member.mode & 0o777
                )  # No setuid/setgid or ownership from guest.

        for name in links:
            if not (root / name).resolve().is_relative_to(root.resolve()):
                raise ValueError("Symlink chain leaves workspace")


def durable_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync_directory(path):
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_metadata(root):
    for directory, folders, files in os.walk(root, followlinks=False):
        if ".git" in folders:
            folders.remove(".git")
            yield Path(directory) / ".git"
        elif ".git" in files:
            yield Path(directory) / ".git"


def preserve_git_metadata(data, original):
    """Project code may change; controller-owned Git configuration may not.

    Never import guest hooks, fsmonitor commands, remotes, objects or index data
    into a repository subsequently opened by Git on the controller.
    """
    with tempfile.TemporaryDirectory() as temporary:
        guest, trusted = Path(temporary) / "guest", Path(temporary) / "trusted"
        guest.mkdir()
        trusted.mkdir()
        unpack(data, guest)
        unpack(original, trusted)
        # Includes newly generated repositories, which are later git-initialized
        # by the controller, and nested repositories in an existing workspace.
        for git in list(git_metadata(guest)):
            if git.is_symlink() or git.is_file():
                git.unlink()
            else:
                shutil.rmtree(git)
        for source in git_metadata(trusted):
            target = guest / source.relative_to(trusted)
            if not target.parent.exists():
                continue  # A deleted nested project stays deleted.
            if source.is_symlink() or any(
                parent.is_symlink() for parent in target.parents
            ):
                raise ValueError("Git metadata cannot traverse a symlink")
            if source.is_dir():
                shutil.copytree(source, target, symlinks=True)
            else:
                shutil.copy2(source, target)
        return pack(guest)


def sync_tree(root):
    for directory, _, files in os.walk(root, followlinks=False, topdown=False):
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                with path.open("rb") as source:
                    os.fsync(source.fileno())
        sync_directory(directory)


def publish(data, root, checkpoint):
    """Keep a durable archive before replacing the working copy; retain rollback."""
    root, checkpoint = Path(root), Path(checkpoint)
    with tempfile.TemporaryDirectory(
        dir=root.parent, prefix=".microvm-stage-"
    ) as temporary:
        stage = Path(temporary) / "workspace"
        stage.mkdir()
        unpack(data, stage)
        durable_write(checkpoint, data)
        sync_tree(stage)
        backup = root.parent / (".microvm-previous-" + checkpoint.parent.name)
        if backup.exists():
            raise RuntimeError("Previous workspace needs recovery before publication")
        os.rename(root, backup)
        try:
            os.rename(stage, root)
            sync_directory(root.parent)
        except BaseException:
            if root.exists():
                os.rename(root, stage)
            os.rename(backup, root)
            sync_directory(root.parent)
            raise
        shutil.rmtree(backup)
