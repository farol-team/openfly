import test from 'node:test';
import assert from 'node:assert/strict';
import {ExecutionPoolClient} from '../clients/javascript/execution-pool-client.mjs';
test('transport retry preserves one idempotent operation identity',async()=>{
 const calls=[];
 const client=new ExecutionPoolClient({url:'https://pool.example',token:'fixture',fetchImpl:async(url,options)=>{calls.push(options);if(calls.length===1)throw Error('lost response');return new Response(JSON.stringify({id:'one-operation'}),{headers:{'content-type':'application/json'}});}});
 assert.equal((await client.request('POST','/v1/sessions/x/operations',{body:{operation_key:'stable'}})).id,'one-operation');
 assert.equal(calls.length,2);assert.equal(calls[0].headers['Idempotency-Key'],calls[1].headers['Idempotency-Key']);
});
test('unknown execution is returned without resubmission',async()=>{
 let count=0;
 const client=new ExecutionPoolClient({url:'http://127.0.0.1:3190',token:'fixture',fetchImpl:async()=>{count++;return new Response(JSON.stringify({state:'unknown',execution_status:'unknown'}),{headers:{'content-type':'application/json'}});}});
 assert.equal((await client.wait('operation')).state,'unknown');assert.equal(count,1);
});
test('credentials cannot follow redirects or use remote cleartext',()=>{
 assert.throws(()=>new ExecutionPoolClient({url:'http://pool.example',token:'fixture'}),/HTTPS/);
 assert.throws(()=>new ExecutionPoolClient({url:'https://a:b@pool.example',token:'fixture'}),/Invalid/);
});
