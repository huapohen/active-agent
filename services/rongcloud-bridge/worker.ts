import * as sdk from '@rongcloud/imlib-next';
declare global { interface Window { trustedReceiveBridge: { start(listener: (config: {app_key:string;provider_token:string;receiver_id:string})=>void):void;report(value:unknown):void;ready():void } } }
const bridge=window.trustedReceiveBridge;
let started=false, identityVerified=false, backlog:unknown[]=[];
bridge.start(async config=>{
  if(started)return;started=true;
  try {
    sdk.init({appkey:config.app_key,logOutputLevel:1});
    sdk.addEventListener(sdk.Events.MESSAGES,event=>{
      for(const message of event.messages ?? []) {
        if(identityVerified)bridge.report({kind:'received',message});
        else if(backlog.length<100)backlog.push(message);
        else bridge.report({kind:'failure',code:'preconnect_buffer_full'});
      }
    });
    sdk.addEventListener(sdk.Events.CONNECTED,()=>{if(identityVerified)bridge.report({kind:'state',state:'connected'});});
    sdk.addEventListener(sdk.Events.DISCONNECT,()=>bridge.report({kind:'state',state:'disconnected'}));
    sdk.addEventListener(sdk.Events.SUSPEND,()=>bridge.report({kind:'state',state:'disconnected'}));
    const result=await sdk.connect(config.provider_token);
    if(result.code!==0 || result.data?.userId!==config.receiver_id){await sdk.disconnect(true,true);backlog=[];bridge.report({kind:'failure',code:'provider_identity_unverified',provider_code:result.code});return;}
    identityVerified=true;
    bridge.report({kind:'identity',receiver_id:result.data.userId});
    bridge.report({kind:'state',state:'connected'});
    for(const message of backlog)bridge.report({kind:'received',message});backlog=[];
  } catch {bridge.report({kind:'failure',code:'provider_connect_failed'});}
});
bridge.ready();
