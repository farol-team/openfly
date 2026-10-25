# OpenFly API v1

Предлагаемый контракт. URL `https://execution.internal.example` — placeholder, не действующий endpoint. Формальное описание: ../api/openapi.json. Все примеры используют фиктивные идентификаторы; здесь нет настоящих credentials.

## Авторизация и общие правила

`Authorization: Bearer <application-service-token>`, TLS. Credential выбирает tenant и scopes; запрос не содержит tenant_id. В guest service-token не передаётся. Роли execution, artifacts и operator разделены. Чужой ID возвращает404, даже если существует. Успешная аутентификация не даёт доступ ко всем templates, profiles или секретам tenant.

Все POST требуют `Idempotency-Key`. Область tenant+method+path. При повторе идентичного запроса возвращается тот же resource с актуальным состоянием; body с тем же ключом, но другими параметрами →409 idempotency_conflict. Для secret-binding idempotency хранится только keyed HMAC digest запроса и безопасные metadata, никогда raw value/body. Эти ключи — не bearer credentials, но их не следует делать из секретов. DELETE повторяем; PUT content разрешает только исходные bytes/hash. Неопределённый сетевой исход проверяется повтором с тем же ключом или GET, а не новым operation_key.

Коды:200 чтение/ack/heartbeat;201 создан ресурс;202 durable очередь/cleanup;204 content принят;400 malformed;401 auth;403 profile/scope;404 unavailable;409 конфликт revision/состояния/ключа;413 размер;422 schema/unsafe archive/checksum;429 tenant quota (Retry-After);503 control-plane unavailable. Недостаток свободной VM обычно даёт202 queued, а не503. Error envelope: `{ "error": { "code":"revision_conflict", "message":"Session revision changed", "request_id":"req_..." } }`. SQL, provider bodies и secrets не попадают в errors.

## Endpoints

| Метод и путь | Действие |
|---|---|
| GET /v1/templates | Только разрешённые tenant шаблоны, immutable digest и profiles |
| GET /v1/quota | Capacity limit/used, queued, reserved; parked тоже считается |
| POST /v1/artifacts | Создать upload metadata, tenant-scoped artifact_id |
| PUT /v1/artifacts/{id}/content | Передать байты; hash/size/архив проверяются до ready |
| GET /v1/artifacts/{id} | Metadata, статус, hash, origin operation, retention |
| GET /v1/artifacts/{id}/content | Скачать ready artifact с проверкой tenant; без публичных URL |
| POST /v1/sessions | Создать логическую среду задачи/version и поставить размещение в очередь |
| GET /v1/sessions/{id} | Статус, generation, revision, VM present, cleanup, last checkpoint |
| DELETE /v1/sessions/{id} | Остановить/удалить;202 означает принято, не подтверждённое удаление |
| POST /v1/secret-bindings | Одноразовая доставка credentials к конкретной session+operation_key |
| DELETE /v1/secret-bindings/{id} | Отзыв; уже прочитанный secret нельзя «забрать обратно» |
| POST /v1/sessions/{id}/operations | Исполнить один шаг с input snapshot и expected revision |
| GET /v1/operations/{id} | Статус, exit, checkpoint/result IDs, lease/deadline, uncertain outcome |
| POST /v1/operations/{id}/heartbeat | Продлить operation lease, но не fixed deadline |
| POST /v1/operations/{id}/cancel | Запросить остановку, вернуть текущий статус; не гарантия остановки удалённой команды |
| POST /v1/operations/{id}/acknowledgement | accepted/discarded после клиентской проверки/публикации |
| GET /v1/operations/{id}/output | stdout/stderr chunks в общем порядке, cursor pagination |
| GET /v1/sessions/{id}/events | Durable lifecycle events, cursor pagination |

Операторская регистрация узлов и изменение квот остаются в отдельном Pool backoffice; публичный node-admin API не нужен в первой версии.

## 1. Передача workspace

```http
POST /v1/artifacts
Idempotency-Key: upload-task-123-input-v7
Content-Type: application/json

{"kind":"workspace_input","media_type":"application/gzip","size_bytes":10240,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
```

Ответ201: `{ "id":"art_input", "state":"pending", ... }`. Затем `PUT /v1/artifacts/art_input/content`, body — файл ровно указанного размера/hash. Для workspace лимит256MiB также применяется после распаковки; ограничены entries и безопасные пути. Пример digest иллюстративный. Запуск с pending или чужим artifact отклоняется. Никакого пути к локальной папке на API host или download-from-URL.

operation_request ограничен1MiB UTF-8 JSON object; workspace_input должен иметь media_type=application/gzip.

Requests с промптом/настройками harness передаются отдельным artifact kind=operation_request (JSON, без credentials). Trusted runner монтирует его read-only в `/run/task/request.json`. Схему business request определяет версия application harness, Pool её не интерпретирует.

## 2. Сессия задачи

```http
POST /v1/sessions
Idempotency-Key: cofounder-task-123-v2

{
  "task_key":"task-123",
  "task_version":"2",
  "workspace_key":"project-45",
  "template_id":"cofounder-runtime-v1",
  "resource_profile":"standard-2cpu-4g",
  "network_profile":"cofounder-build",
  "ttl_seconds":3600,
  "idle_timeout_seconds":600
}
```

Template ID immutable and maps to pinned digest. Uniqueness active `(tenant, task_key, task_version)`; repeated creation with another key returns409 existing_session, not a second VM. workspace_key is opaque tenant-scoped identity, NOT filesystem path. Different sessions for same workspace may exist, but only one can hold operation writer lock; conflict returns409 workspace_busy.

```json
{"id":"ses_123","state":"queued","generation":0,"revision":0,"vm_present":false,"cleanup_status":"none","expires_at":"2026-10-25T14:00:00Z","idle_timeout_seconds":600,"last_accepted_checkpoint_id":null}
```

VM changes increment generation. Внутренний lease_epoch меняется при каждой передаче operation writer authority, даже на той же VM; generation не служит fencing-token. Revision increments only on acknowledged accepted checkpoint (expected revision +1). Expired/evicted VM does not increment session revision. No stable IP/provider_id is part of the application contract. Guest caches are best effort and are not persistent application data.

## 3. Операция

```http
POST /v1/sessions/ses_123/operations
Idempotency-Key: build-step-01

{
  "operation_key":"build-step-01",
  "app_run_id":"cofounder-run-456",
  "expected_session_revision":0,
  "input_workspace_revision":"app-workspace-sha256-v7",
  "input_artifact_id":"art_input",
  "request_artifact_id":"art_request",
  "argv":["/opt/cofounder/bin/guest-operation","agent"],
  "cwd":"/workspace",
  "permission_profile":"workspace-write",
  "timeout_seconds":1800,
  "secret_binding_ids":["sec_model"]
}
```

Ответ202 содержит operation ID, server-selected generation/lease expiry и fixed deadline. `operation_key` уникален в session и не переиспользуется для другого исполнения. Generic argv запускается только ВНУТРИ VM под непривилегированным user. cwd ограничен workspace; доступ к `/opt` read-only, privilege escalation запрещён. Permission profile проверяется при каждом шаге; Cofounder review использует workspace-read с writable scratch outside project и защитой по digest проекта.

Каждая операция перед стартом восстанавливает authoritative input snapshot, включая удаления; caches вне workspace допустимы. Одновременно выполнять ещё одну операцию нельзя. Writer lock tenant/workspace удерживается до accepted/discarded ack или явного operator resolution, включая время после terminal state и закрытия VM. Приложение также сохраняет свой workspace lock от input snapshot до durable publish marker; Pool не видит конкурентных локальных edits. Session в состоянии pending acknowledgement не принимает следующий шаг. VM startup может оставить operation queued; heartbeat обязателен с момента приёма. Queue wait ограничен300s. Deadline фиксируется как min(session.expires_at, accepted_at + queue_wait_budget + timeout_seconds); execution timer начинается с запуска, никогда не выходит за fixed deadline. Недостаток capacity по истечении queue wait → timed_out с execution_status=not_started, без выполнения argv.

input_workspace_revision — opaque версия/digest authoritative файлов у приложения. Pool возвращает её неизменной вместе с input_artifact_sha256. expected_session_revision защищает последовательность session и не заменяет app CAS между разными sessions.

Secret binding создаётся заранее для session+operation_key, TTL<=3600s; значение доступно только trusted worker и соответствующему guest mount/env. К моменту запуска срок binding должен покрывать remaining execution deadline; иначе failed с error_code=secret_unavailable до старта. Secret consume атомарно связывается с operation_key и внутренней попыткой/lease_epoch; value не выдаётся второй раз по повтору dispatch. Binding не логируется, не включается в request artifact; replay POST secret-binding с тем же ключом не обновляет TTL/value. После рестарта secret service value недоступен: старый шаг не запускается скрытно с другим secret. Клиент создаёт новую операцию после подтверждённого execution_status=not_started и нового binding.

## 4. Heartbeat, события и результат

Каждые15s: `POST /v1/operations/op_456/heartbeat`, пустой body, новый idempotency key для каждого heartbeat. Ответ `{ "lease_expires_at":"..." }`, TTL90s. Terminal/expired/fenced lease →409 lease_inactive; старый heartbeat никогда не оживляет операцию. Секрет lease не передаётся клиенту — доступ проверяется по tenant token и operation ownership; fencing token доступен только внутренним trusted workers.

`GET /v1/sessions/ses_123/events?after=103&limit=100` возвращает events с монотонными seq, occurred_at, operation_id, type, безопасными details, next_cursor и has_more. Аналогичный GET output выдаёт seq/stream/text; общий порядок stdout/stderr фиксируется в gateway при приёме. Ограничение страницы100 chunks, chunk<=16KiB. У output есть truncated/redacted/capture_complete; отсутствие новых bytes не означает completion. Retention исчерпан →410 cursor_expired или artifact_expired, с явным error code, а не пустой якобы полный журнал. В v1 polling; SSE можно добавить без изменения жизненного цикла.

```json
{
  "id":"op_456","session_id":"ses_123","state":"succeeded",
  "execution_status":"started","exit_code":0,
  "generation":1,"expected_session_revision":0,
  "input_workspace_revision":"app-workspace-sha256-v7",
  "input_artifact_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "publication_eligibility":"eligible",
  "candidate_checkpoint_id":"art_output",
  "result_artifact_id":"art_result",
  "checkpoint_status":"ready","acknowledgement":null,
  "lease_expires_at":null,"deadline":"2026-10-25T13:35:00Z",
  "error_code":null,"requires_reconciliation":false
}
```

Harness пишет structured result JSON в `/run/task/result.json` (не secret, writable scratch; request.json read-only). Лимит1MiB UTF-8 JSON object, без symlink. Trusted runner после quiesce забирает и валидирует этот файл ДО scrub request/result scratch; сохраняет immutable result artifact. Отсутствие result допустимо для generic shell operation, result_artifact_id=null; Cofounder adapter обязан отвергнуть отсутствующий/неверный обязательный agent/check result. Pool проверяет generic JSON/размер, а конкретную схему приложения — клиент. Invalid result ставит failed/error_code=invalid_result; snapshot при этом может быть пригоден для исправления. Exit!=0/test failure может сопровождаться candidate checkpoint, чтобы продолжить исправление. Candidate готов только после остановки guest processes, очистки ephemeral secrets и durable validation. `checkpoint_status=unavailable/recovery_only` запрещает обычный publish.

Поле execution_status: not_started — есть подтверждение, что argv не был запущен; started — запуск подтверждён; unknown — dispatch мог произойти. Только not_started позволяет приложению начать новую попытку без проверки side effects.

При потере исполнителя: `state=unknown`, `requires_reconciliation=true`, даже если stdout содержит «успех». GET/повтор submit возвращает эту же операцию; нового исполнения нет. Duke42 проверяет целевой сервер через независимый broker. VM checkpoint не является бэкапом клиентского сайта.

## 5. Публикация и следующий шаг

Cofounder скачивает checkpoint, проверяет hash/безопасный tar, сохраняет собственную доверенную Git metadata, сверяет исходный workspace digest под локальной блокировкой, затем atomically publishes. Его durable marker хранит operation ID/checkpoint hash. Pool не имеет доступа к writable repo Cofounder.

```http
POST /v1/operations/op_456/acknowledgement
Idempotency-Key: publish-step-01

{"decision":"accepted","checkpoint_id":"art_output","expected_session_revision":0,"input_workspace_revision":"app-workspace-sha256-v7"}
```

Ответ200 `{ "operation_id":"op_456", "decision":"accepted", "session_revision":1 }`. accepted требует terminal succeeded/failed, ready candidate именно этой операции, matching expected_session_revision, исходную input_workspace_revision операции и durable publication_eligibility=eligible. Eligibility атомарно присваивается terminal результату после проверки актуального lease_epoch, а не проверяется по живой lease во время ack. Session expiry, eviction, DELETE и потеря live lease после terminal commit не отзывают eligibility. Это устраняет окно «клиент опубликовал, но Pool отверг ack из-за истечения VM». После tenant acknowledgement workspace writer lock освобождается; competing или изменённый ack отклоняется. Input/candidate/result pending-ack защищены от retention pruning, даже если VM закрыта; зависший ack требует alert/operator resolution, не молчаливый unlock. Повтор идентичного ack безопасен; conflicting decision/revision →409.

При локальном конфликте: decision=discarded, expected_session_revision=0, checkpoint_id=null и исходная input_workspace_revision. Revision остаётся0; следующий шаг загружает новую authoritative input копию приложения. Исход unknown не принимается как accepted, пока отдельная operator reconciliation не завершит разбор; для безопасного продолжения на новой session клиент может discarded и восстановить подтверждённое состояние. discarded не освобождает orphan capacity и не утверждает, что внешняя команда не выполнилась.

VM после cleanup паркуется и может использоваться той же задачей/version. Она занимает квоту до удаления. DELETE session отменяет active шаг, сохраняет доступное recovery evidence, требует независимого подтверждения cleanup. На подтверждённый terminated tombstone повтор DELETE возвращает200 без повторного side effect.
