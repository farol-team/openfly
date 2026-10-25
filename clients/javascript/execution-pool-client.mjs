import {randomUUID,createHash} from 'node:crypto';
export class PoolError extends Error {
 constructor(code,status){super(`Execution Pool ${code} (${status})`);this.code=code;this.status=status;}
}
export class ExecutionPoolClient {
 constructor({url,token,fetchImpl=fetch}){
  this.url=new URL(url);this.token=token;this.fetch=fetchImpl;
  if(this.url.protocol!=='https:'&&!(this.url.protocol==='http:'&&['127.0.0.1','localhost','[::1]'].includes(this.url.hostname)))throw Error('HTTPS or loopback required');
  if(this.url.username||this.url.password||this.url.search||this.url.hash||this.url.pathname!=='/')throw Error('Invalid API URL');
 }
 async request(method,path,{body,key=method==='POST'?randomUUID():undefined,binary=false}={}){
  if(!path.startsWith('/v1/')||path.includes('..'))throw Error('Invalid API path');
  for(let attempt=0;attempt<3;attempt++){
   let response;
   try{response=await this.fetch(new URL(path,this.url),{method,redirect:'error',headers:{Authorization:`Bearer ${this.token}`,'Content-Type':binary?'application/octet-stream':'application/json',...(key?{'Idempotency-Key':key}:{})},body:body===undefined?undefined:binary?body:JSON.stringify(body),signal:AbortSignal.timeout(60000)});}
   catch{if(attempt<2)continue;throw new PoolError('transport_unavailable',503);}
   if(!response.ok){let code='unavailable';try{code=(await response.json()).error?.code||code;}catch{}throw new PoolError(code,response.status);}
   if(response.status===204)return null;
   return response.headers.get('content-type')?.includes('application/json')?response.json():Buffer.from(await response.arrayBuffer());
  }
 }
 async upload(bytes,{kind='workspace_input',key=randomUUID()}={}){
  const artifact=await this.request('POST','/v1/artifacts',{key,body:{kind,media_type:kind==='operation_request'?'application/json':'application/gzip',size_bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')}});
  await this.request('PUT',`/v1/artifacts/${artifact.id}/content`,{body:bytes,binary:true});return artifact.id;
 }
 async wait(id,{signal,pollMs=1000}={}){
  let heartbeat=0;
  for(;;){
   const op=await this.request('GET',`/v1/operations/${id}`);
   if(['succeeded','failed','canceled','timed_out','interrupted','unknown'].includes(op.state))return op;
   if(signal?.aborted){await this.request('POST',`/v1/operations/${id}/cancel`,{key:`cancel-${id}`,body:{}});return this.request('GET',`/v1/operations/${id}`);}
   if(Date.now()-heartbeat>=15000){
    try{await this.request('POST',`/v1/operations/${id}/heartbeat`,{body:{}});}catch(error){if(error.code==='lease_inactive')continue;throw error;}
    heartbeat=Date.now();
   }
   await new Promise(resolve=>setTimeout(resolve,pollMs));
  }
 }
}
