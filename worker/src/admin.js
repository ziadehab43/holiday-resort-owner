import {DateTime} from 'luxon';

// Every route is called only after Firebase JWT verification in index.js.
export function assertAdmin(user) {
  if (user?.data.role !== 'admin' || user.data.isActive !== true) {
    const error = new Error('Active Admin account required.');
    error.status = 403; error.code = 'permission-denied'; throw error;
  }
}
export function validateUnits(units) {
  if (!Array.isArray(units) || units.length < 1 || units.length > 30) throw new Error('Provide between 1 and 30 units.');
  const seen = new Set();
  for (const unit of units) {
    if (!/^[1-9]$/.test(String(unit.buildingNumber)) || !/^\d{1,6}$/.test(String(unit.unitNumber)) || !/^-?\d{1,2}$/.test(String(unit.floorNumber))) throw new Error('Invalid building, unit or floor.');
    const key = `${unit.buildingNumber}:${unit.unitNumber}`;
    if (seen.has(key)) throw new Error('Duplicate unit assignment.');
    seen.add(key);
  }
}
export function ownerSearchKeys(name, units) {
  const keys=new Set([name.trim().toLowerCase()]);
  for(const word of name.trim().toLowerCase().split(/\s+/))for(let i=1;i<=word.length;i++)keys.add(word.slice(0,i));
  for(const unit of units){keys.add(String(unit.buildingNumber));keys.add(String(unit.unitNumber));keys.add(`${unit.buildingNumber}:${unit.unitNumber}`);}
  return [...keys];
}
export function createAdminHandler(d) {
  const {ApiError, serviceAccessToken, getDocument, firestoreFetch, documentsBase, documentName, encodeValue, withTransaction, requiredString} = d;
  const encode = data => Object.fromEntries(Object.entries(data).map(([k,v]) => [k,encodeValue(v)]));
  const fail = (code, message, status=400) => {throw new ApiError(status,code,message);};
  const id = (body,key='id') => {const v=requiredString(body,key,128); if (!/^[\w-]+$/.test(v)) fail('invalid-argument','Invalid record identifier.'); return v;};
  const filter = (fieldPath, value, op='EQUAL') => ({fieldFilter:{field:{fieldPath},op,value:encodeValue(value)}});
  const combined = (filters,op='AND') => filters.length===1?filters[0]:{compositeFilter:{op,filters}};
  const write = (env,path,data,old) => ({update:{name:documentName(env,path),fields:encode(data)},...(old?{updateMask:{fieldPaths:Object.keys(data)},currentDocument:{updateTime:old.updateTime}}:{currentDocument:{exists:false}})});
  async function query(env,token,collection,filters=[],order='__name__',direction='ASCENDING',limit=31,cursor=null,transaction) {
    const structuredQuery={from:[{collectionId:collection}],limit,orderBy:[{field:{fieldPath:order},direction},...(order==='__name__'?[]:[{field:{fieldPath:'__name__'},direction}])],...(filters.length?{where:combined(filters)}:{})};
    if(cursor){
      if(typeof cursor.id!=='string'|| !/^[\w-]+$/.test(cursor.id)) fail('invalid-argument','Invalid page cursor.');
      structuredQuery.startAt={before:false,values:[...(order==='__name__'?[]:[encodeValue(order.endsWith('At')?new Date(cursor.value):cursor.value)]),{referenceValue:documentName(env,`${collection}/${cursor.id}`)}]};
    }
    const rows=await firestoreFetch(env,token,`${documentsBase(env)}:runQuery`,{method:'POST',body:JSON.stringify({structuredQuery,...(transaction?{transaction}:{})})});
    return rows.filter(r=>r.document).map(r=>d.decodeDocument(r.document));
  }
  const record = r => ({id:r.name.split('/').pop(),...r.data});
  const entryIds = data => ({...Object.fromEntries(Object.entries(data.adultImages||{}).map(([key,v])=>[key,{idStatus:'provided',...v}])),...(data.adultIdentifications||{})});
  async function authCall(env,token,action,body){
    let response;
    try { response=await fetch(`https://identitytoolkit.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/accounts${action === 'signUp' ? '' : ':' + action}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(body)}); }
    catch (_) { fail('auth-update-failed','Authentication service could not be reached. Retry to resume the saved operation.',503); }
    if(!response.ok){
      const result=await response.json().catch(()=>({}));
      const upstreamCode=String(result.error?.message||result.error?.status||'UNKNOWN').match(/^[A-Z][A-Z0-9_]{0,79}/)?.[0]||'UNKNOWN';
      console.error(JSON.stringify({event:'firebase-auth-failed',action,status:response.status,code:upstreamCode,serviceAccount:env.FIREBASE_CLIENT_EMAIL}));
      if(upstreamCode==='EMAIL_EXISTS')fail('duplicate-email','This email is already registered.',409);
      if(['USER_NOT_FOUND','EMAIL_NOT_FOUND'].includes(upstreamCode))fail('auth-user-not-found','The linked Authentication account is missing. Contact support; do not recreate the owner.',404);
      if(['INSUFFICIENT_PERMISSION','PERMISSION_DENIED'].includes(upstreamCode)||response.status===403)fail('backend-config-error','Account administration is unavailable because backend permissions need repair. Contact support.',503);
      if(upstreamCode==='INVALID_PASSWORD'||upstreamCode==='PASSWORD_DOES_NOT_MEET_REQUIREMENTS')fail('invalid-password','The password does not meet the Firebase project policy.');
      fail('auth-update-failed','Authentication rejected the update. Retry recovery or contact support.',502);
    }
    return response.json();
  }
  async function authOwner(env,token,uid){
    const result=await authCall(env,token,'lookup',{localId:[uid]});
    const user=result.users?.find(u=>u.localId===uid);
    if(!user)fail('auth-user-not-found','The linked Authentication account is missing. Contact support; do not recreate the owner.',404);
    return user;
  }
  async function recover(env,claims,uid){
    const token=await serviceAccessToken(env),r=await getDocument(env,token,`users/${uid}`);
    if(r?.data.role!=='owner')fail('owner-not-found','Owner not found.',404);
    if(!r.data.adminOperation){
      const user=await authOwner(env,token,uid);
      if((user.disabled===true)=== (r.data.isActive===true)||user.email?.toLowerCase()!==r.data.email?.toLowerCase())fail('invalid-owner-state','Auth and owner profile disagree. Use Activate/Deactivate or edit the account to reconcile it.',409);
      return {ok:true,alreadyConsistent:true};
    }
    if(r.data.adminOperation.kind==='state')return finishState(env,claims,uid);
    if(!['create','update'].includes(r.data.adminOperation.kind))fail('invalid-owner-state','Unknown account operation. Contact support.',409);
    try { return await finishOwner(env,claims,uid); }
    catch(error){
      if(error.code!=='duplicate-email'||r.data.adminOperation.kind!=='update')throw error;
      const op=r.data.adminOperation,user=await authOwner(env,token,uid);
      if(user.email?.toLowerCase()!==op.previousEmail?.toLowerCase())throw error;
      await authCall(env,token,'update',{localId:uid,disableUser:!op.desiredActive});
      const verified=await authOwner(env,token,uid);
      if(verified.email?.toLowerCase()!==op.previousEmail?.toLowerCase()||(verified.disabled===true)!==!op.desiredActive)throw error;
      return withTransaction(env,async({token,transaction})=>{
        assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
        const current=await getDocument(env,token,`users/${uid}`,transaction);
        if(current?.data.adminOperation?.operationId!==op.operationId)fail('operation-pending','Account changed during rollback. Retry.',409);
        const reserved=[];for(const unitId of op.unitIds)reserved.push(await getDocument(env,token,`units/${unitId}`,transaction));
        return {writes:[write(env,`users/${uid}`,{isActive:op.desiredActive,adminOperation:null},current),...reserved.filter(u=>u?.data.adminReservation===uid).map(u=>write(env,`units/${u.name.split('/').pop()}`,{adminReservation:null},u))],result:{ok:true,rolledBack:true,message:'The requested email is already registered. The previous account and units were restored; the edit was not applied.'}};
      });
    }
  }
  async function ownerUnits(env,token,uid,transaction){return query(env,token,'units',[filter('ownerId',uid)],'__name__','ASCENDING',100,null,transaction);}
  const legacyUnitValue=(data,canonical,...legacy)=>{
    for(const [key,value] of Object.entries(data))if([canonical,...legacy].includes(key.trim())&&value!==null&&value!==undefined)return String(value).trim();
    return '';
  };
  async function resolveUnits(env,token,units,uid,transaction,{allowCreate=false,creatingOwner=false}={}){
    try{validateUnits(units);}catch(e){fail('invalid-units',e.message);}
    const result=[],all=await query(env,token,'units',[],'__name__','ASCENDING',1000,null,transaction);
    for(const u of units){
      const building=String(u.buildingNumber).trim(),unit=String(u.unitNumber).trim(),floor=String(u.floorNumber).trim();
      const requestedId=typeof u.id==='string'&&/^[\w-]+$/.test(u.id)?u.id:null;
      let rows=all.filter(r=>legacyUnitValue(r.data,'buildingNumber','building','building_number')===building&&legacyUnitValue(r.data,'unitNumber','unit','unit_number')===unit);
      if(requestedId){
        const selected=all.find(r=>r.name.split('/').pop()===requestedId);
        if(!selected||selected.data.ownerId!==uid)fail('unit-not-found','The selected unit no longer belongs to this owner.',404);
        const conflicts=rows.filter(r=>r.name!==selected.name);
        if(conflicts.length)fail('unit-conflict','Another physical unit already uses this building and unit number.',409);
        rows=[selected];
      }
      if(rows.length>1)fail('duplicate-unit-records','Multiple unit records match this building and unit. Resolve the duplicate master records before assigning an owner.',409);
      if(rows.length===0){
        if(!allowCreate)continue;
        const unitId='unit_'+crypto.randomUUID();
        result.push({name:documentName(env,`units/${unitId}`),data:{buildingNumber:building,unitNumber:unit,floorNumber:floor,ownerId:null,isActive:false},desiredFloor:floor,canonicalBuilding:building,canonicalUnit:unit,isNew:true});
        continue;
      }
      const r=rows[0];
      if((r.data.adminReservation&&r.data.adminReservation!==uid)||(r.data.ownerId&&r.data.ownerId!==uid))fail('unit-assigned',`Building ${building}, Unit ${unit} is already assigned to another owner.`,409);
      if(creatingOwner&&r.data.ownerId===uid)fail('unit-already-assigned-to-owner','This unit is already assigned to this owner.',409);
      result.push({...r,desiredFloor:floor,canonicalBuilding:building,canonicalUnit:unit,isNew:false});
    }
    return result;
  }
  async function finishState(env,claims,uid) {
    const token=await serviceAccessToken(env),r=await getDocument(env,token,`users/${uid}`),op=r?.data.adminOperation;
    if(r?.data.role!=='owner'||op?.kind!=='state')fail('operation-pending','No account state operation to resume.',409);
    await authOwner(env,token,uid);
    await ownerUnits(env,token,uid);
    await authCall(env,token,'update',{localId:uid,disableUser:!op.desiredActive,validSince:String(Math.floor(Date.now()/1000))});
    const verified=await authOwner(env,token,uid);
    if((verified.disabled===true)!==!op.desiredActive || (op.email && verified.email?.toLowerCase()!==op.email.toLowerCase()))fail('auth-update-failed','Authentication state was not confirmed. Retry recovery.',503);
    return withTransaction(env,async({token,transaction})=>{
      assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
      const current=await getDocument(env,token,`users/${uid}`,transaction);
      if(current?.data.adminOperation?.operationId!==op.operationId)fail('operation-pending','Account state changed. Refresh and retry.',409);
      return {writes:[write(env,`users/${uid}`,{isActive:op.desiredActive,adminOperation:null},current)],result:{ok:true}};
    });
  }

  async function finishOwner(env,claims,uid) {
    const token=await serviceAccessToken(env);
    const owner=await getDocument(env,token,`users/${uid}`),op=owner?.data.adminOperation;
    if(owner?.data.role!=='owner'||!op)fail('operation-pending','No recoverable operation was found.',409);
    if(!Array.isArray(op.unitIds)||typeof op.desiredActive!=='boolean'||!op.name||!op.email)fail('invalid-owner-state','Incomplete saved update. Contact support.',409);
    await authOwner(env,token,uid);
    for(const unitId of op.unitIds){const u=await getDocument(env,token,`units/${unitId}`);if(!u||u.data.adminReservation!==uid||(u.data.ownerId&&u.data.ownerId!==uid))fail('unit-assigned','Saved unit reservation changed. Contact support to reconcile it.',409);}
    await authCall(env,token,'update',{localId:uid,email:op.email,displayName:op.name,disableUser:!op.desiredActive});
    return withTransaction(env,async({token,transaction})=>{
      assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
      const current=await getDocument(env,token,`users/${uid}`,transaction);
      if(current?.data.adminOperation?.operationId!==op.operationId)fail('operation-pending','The account operation changed. Refresh and retry.',409);
      const selected=[];
      for(const unitId of op.unitIds){const r=await getDocument(env,token,`units/${unitId}`,transaction);if(!r||r.data.adminReservation!==uid||(r.data.ownerId&&r.data.ownerId!==uid))fail('unit-assigned','Reserved unit changed.',409);selected.push(r);}
      const previous=await ownerUnits(env,token,uid,transaction);
      return {writes:[write(env,`users/${uid}`,{name:op.name,email:op.email,isActive:op.desiredActive,adminOperation:null,searchKeys:ownerSearchKeys(op.name,selected.map(r=>({...r.data,buildingNumber:op.unitBuildings?.[r.name.split('/').pop()]??r.data.buildingNumber,unitNumber:op.unitNumbers?.[r.name.split('/').pop()]??r.data.unitNumber,floorNumber:op.unitFloors?.[r.name.split('/').pop()]??r.data.floorNumber})))},current),...selected.map(r=>write(env,`units/${r.name.split('/').pop()}`,{buildingNumber:op.unitBuildings?.[r.name.split('/').pop()]??legacyUnitValue(r.data,'buildingNumber','building','building_number'),unitNumber:op.unitNumbers?.[r.name.split('/').pop()]??legacyUnitValue(r.data,'unitNumber','unit','unit_number'),floorNumber:op.unitFloors?.[r.name.split('/').pop()]??legacyUnitValue(r.data,'floorNumber','floor'),ownerId:uid,isActive:true,adminReservation:null},r)),...previous.filter(r=>!selected.some(s=>s.name===r.name)).map(r=>write(env,`units/${r.name.split('/').pop()}`,{ownerId:null,isActive:false},r))],result:{id:uid}};
    });
  }
  async function saveOwner(env,claims,body,creating){
    const uid=creating?id(body,'requestId'):id(body);
    const name=requiredString(body,'name',120),email=requiredString(body,'email',254).toLowerCase();
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail('invalid-email','Enter a valid email.');
    if(creating && (typeof body.password!=='string'||body.password.length<6||body.password.length>128)) fail('invalid-password','Use at least 6 characters. Firebase project policy also applies.');
    const token=await serviceAccessToken(env);
    const old=await getDocument(env,token,`users/${uid}`);
    if(creating && old) fail('request-already-used','This request already exists. Refresh the owners list before retrying.',409);
    if(!creating && old?.data.role!=='owner') fail('not-found','Owner not found.',404);
    if(old?.data.adminOperation) fail('operation-pending','Recover the pending account update first.',409);
    if(!creating)await authOwner(env,token,uid);
    await resolveUnits(env,token,body.units,uid,null,{allowCreate:false,creatingOwner:creating});
    if(creating) await authCall(env,token,'signUp',{localId:uid,email,password:body.password,displayName:name,disabled:true});
    const operationId=crypto.randomUUID();
    try {
      await withTransaction(env,async({token,transaction})=>{
        assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
        const current=await getDocument(env,token,`users/${uid}`,transaction);
        if(creating?!!current:current?.updateTime!==old.updateTime)fail('operation-pending','Owner changed. Refresh before saving.',409);
        const units=await resolveUnits(env,token,body.units,uid,transaction,{allowCreate:true,creatingOwner:creating});
        const adminOperation={kind:creating?'create':'update',operationId,name,email,desiredActive:creating?true:old.data.isActive===true,unitIds:units.map(r=>r.name.split('/').pop()),unitFloors:Object.fromEntries(units.map(r=>[r.name.split('/').pop(),r.desiredFloor])),unitBuildings:Object.fromEntries(units.map(r=>[r.name.split('/').pop(),r.canonicalBuilding])),unitNumbers:Object.fromEntries(units.map(r=>[r.name.split('/').pop(),r.canonicalUnit])),previousName:old?.data.name||'',previousEmail:old?.data.email||'',startedAt:new Date().toISOString()};
        const next=creating?{name,email,role:'owner',isActive:false,adminOperation}:{isActive:false,adminOperation};
        return {writes:[write(env,`users/${uid}`,next,current),...units.map(r=>write(env,`units/${r.name.split('/').pop()}`,r.isNew?{buildingNumber:r.canonicalBuilding,unitNumber:r.canonicalUnit,floorNumber:r.desiredFloor,ownerId:null,isActive:false,adminReservation:uid}:{adminReservation:uid},r.isNew?null:r))],result:{}};
      });
      return await finishOwner(env,claims,uid);
    }catch(error){
      // A known rejected Auth update can be compensated. Unknown network outcomes
      // remain locked and can be resumed idempotently by /admin/recover-owner.
      const current=await getDocument(env,token,`users/${uid}`);
      if(creating && !current) await authCall(env,token,'delete',{localId:uid}).catch(()=>{});
      if(!creating && error.code==='duplicate-email' && current?.data.adminOperation?.operationId===operationId){
        await withTransaction(env,async({token,transaction})=>{
          const r=await getDocument(env,token,`users/${uid}`,transaction);
          if(r?.data.adminOperation?.operationId!==operationId)fail('operation-pending','Recovery required.',409);
          const reserved=[];
          for(const unitId of r.data.adminOperation.unitIds)reserved.push(await getDocument(env,token,`units/${unitId}`,transaction));
          return {writes:[write(env,`users/${uid}`,{isActive:old.data.isActive,adminOperation:null},r),...reserved.filter(u=>u?.data.adminReservation===uid).map(u=>write(env,`units/${u.name.split('/').pop()}`,{adminReservation:null},u))],result:{}};
        });
      }
      throw error;
    }
  }
  return async function admin(env,claims,path,body){
    const token=await serviceAccessToken(env);
    const caller=await getDocument(env,token,`users/${claims.sub}`);
    try{assertAdmin(caller);}catch(_){fail('permission-denied','Active Admin account required.',403);}
    if(path==='/admin/session') return {profile:{id:claims.sub,name:caller.data.name||'Admin',email:caller.data.email||''}};
    if(path==='/admin/unread') {
      // Missing and explicit-null read markers are both unread. Aggregate counts
      // support old Owner clients without a trigger, listener or full download.
      const aggregate=async(where,readTime)=>firestoreFetch(env,token,`${documentsBase(env)}:runAggregationQuery`,{method:'POST',body:JSON.stringify({structuredAggregationQuery:{structuredQuery:{from:[{collectionId:'reports'}],...(where?{where}:{})},aggregations:[{alias:'count',count:{}}]},...(readTime?{readTime}:{})})});
      const total=await aggregate();
      const read=await aggregate({unaryFilter:{field:{fieldPath:'adminReadAt'},op:'IS_NOT_NULL'}},total[0]?.readTime);
      return {unread:Number(total[0]?.result?.aggregateFields?.count?.integerValue||0)>Number(read[0]?.result?.aggregateFields?.count?.integerValue||0)};
    }
    if(path==='/admin/activity') {
      const entries=await query(env,token,'gate_entries',[],'enteredAt','DESCENDING',5);
      const reports=await query(env,token,'reports',[],'createdAt','DESCENDING',5);
      const items=[...entries.map(r=>({...record(r),kind:'entry'})),...reports.map(r=>({...record(r),kind:'report'}))].sort((a,b)=>Date.parse(b.enteredAt||b.createdAt)-Date.parse(a.enteredAt||a.createdAt)).slice(0,5);
      return {items:items.map(({id,kind,type,ownerName,buildingNumber,unitNumber,enteredAt,createdAt})=>({id,kind,type,ownerName,buildingNumber,unitNumber,enteredAt,createdAt}))};
    }
    if(path==='/admin/recover-owner') return recover(env,claims,id(body));
    if(path==='/admin/create-owner') return saveOwner(env,claims,body,true);
    if(path==='/admin/update-owner') return saveOwner(env,claims,body,false);
    if(path==='/admin/owner'){
      const uid=id(body),r=await getDocument(env,token,`users/${uid}`);
      if(r?.data.role!=='owner') fail('not-found','Owner not found.',404);
      return {owner:record(r),units:(await ownerUnits(env,token,uid)).map(record)};
    }
    if(path==='/admin/reset-password'){
      const uid=id(body),r=await getDocument(env,token,`users/${uid}`);
      if(r?.data.role!=='owner')fail('owner-not-found','Owner not found.',404);
      if(r.data.adminOperation)await recover(env,claims,uid);
      await authOwner(env,token,uid);
      if(typeof body.password!=='string'||body.password.length<6||body.password.length>128) fail('invalid-password','Use at least 6 characters. Firebase project policy also applies.');
      await authCall(env,token,'update',{localId:uid,password:body.password,validSince:String(Math.floor(Date.now()/1000))}); return {ok:true};
    }
    if(path==='/admin/owner-active'){
      const uid=id(body); if(typeof body.isActive!=='boolean')fail('invalid-argument','Choose an account state.');
      const original=await getDocument(env,token,`users/${uid}`);
      if(original?.data.role!=='owner')fail('owner-not-found','Owner not found.',404);
      if(original.data.adminOperation)await recover(env,claims,uid);
      const auth=await authOwner(env,token,uid);
      const profile=await getDocument(env,token,`users/${uid}`);
      if(auth.email?.toLowerCase()!==profile.data.email?.toLowerCase())fail('invalid-owner-state','Authentication email differs from the owner profile. Recover or edit the account first.',409);
      await ownerUnits(env,token,uid);
      const staged=await withTransaction(env,async({token,transaction})=>{
        assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
        const r=await getDocument(env,token,`users/${uid}`,transaction);
        if(r?.data.role!=='owner')fail('owner-not-found','Owner not found.',404);
        if(r.data.adminOperation)fail('operation-pending','Another account update is in progress. Retry recovery.',409);
        if(r.data.isActive===body.isActive&&(auth.disabled===true)===!body.isActive)return {writes:[],result:{already:true}};
        return {writes:[write(env,`users/${uid}`,{isActive:false,adminOperation:{kind:'state',operationId:crypto.randomUUID(),desiredActive:body.isActive,previousActive:r.data.isActive===true,startedAt:new Date().toISOString()}},r)],result:{}};
      });
      if(staged.already)return {ok:true,alreadyInRequestedState:true};
      return finishState(env,claims,uid);
    }
    if(path==='/admin/entries' || path==='/admin/reports' || path==='/admin/owners' || path==='/admin/units'){
      const kind=path.split('/').pop(),collection={entries:'gate_entries',reports:'reports',owners:'users',units:'units'}[kind];
      const filters=[];let order=kind==='entries'?'enteredAt':kind==='reports'?'createdAt':'__name__';
      const direction=body.oldest?'ASCENDING':order==='__name__'?'ASCENDING':'DESCENDING';
      if(kind==='owners') {filters.push(filter('role','owner')); if(typeof body.isActive==='boolean') filters.push(filter('isActive',body.isActive));}
      if(kind==='entries'){
        if(body.today){const start=DateTime.now().setZone('Africa/Cairo').startOf('day');filters.push(filter('enteredAt',start.toJSDate(),'GREATER_THAN_OR_EQUAL'),filter('enteredAt',start.plus({days:1}).toJSDate(),'LESS_THAN'));}
        else for(const [key,op] of [['from','GREATER_THAN_OR_EQUAL'],['to','LESS_THAN']]) if(body[key]) {const date=DateTime.fromISO(body[key],{zone:'Africa/Cairo'});if(!date.isValid)fail('invalid-date','Invalid date range.');filters.push(filter('enteredAt',date.toJSDate(),op));}
        if(body.type){if(!['guest','delivery'].includes(body.type))fail('invalid-type','Invalid entry type.');filters.push(filter('type',body.type));}
      }
      if(kind==='reports' && body.status){if(!['pending','in_progress','resolved'].includes(body.status))fail('invalid-status','Invalid status.');filters.push(body.status==='in_progress'?filter('status',['in_progress','under_review'],'IN'):filter('status',body.status));}
      const search=typeof body.search==='string'?body.search.trim().slice(0,120):'';
      if(search){
        if(kind==='owners'){
          filters.push(filter('searchKeys',search.toLowerCase(),'ARRAY_CONTAINS'));
        }else filters.push(combined(['ownerName','buildingNumber','unitNumber'].map(k=>filter(k,search)),'OR'));
      }
      const rows=await query(env,token,collection,filters,order,direction,31,body.cursor);
      const selected=rows.slice(0,30),last=selected.at(-1);
      const items=await Promise.all(selected.map(async r=>{
        const item=record(r);
        if(kind==='owners') item.units=(await ownerUnits(env,token,item.id)).map(record);
        if(kind==='reports' && !item.buildingNumber && item.unitId){const unit=await getDocument(env,token,`units/${item.unitId}`);item.buildingNumber=unit?.data.buildingNumber||null;}
        if(kind==='entries'){delete item.adultIdentifications;delete item.adultImages;delete item.securityUserId;delete item.draftId;}
        return item;
      }));
      return {items,cursor:rows.length>30?{id:last.name.split('/').pop(),value:last.data[order]||null}:null};
    }
    if(path==='/admin/entry'){
      const r=await getDocument(env,token,`gate_entries/${id(body)}`);if(!r)fail('not-found','Entry not found.',404);
      const item=record(r);delete item.securityUserId;delete item.adultImages;delete item.draftId;
      item.adultIdentifications=Object.fromEntries(Object.entries(entryIds(r.data)).map(([k,v])=>[k,{idStatus:v.idStatus,hasFront:!!v.frontPath,hasBack:!!v.backPath}]));
      return {entry:item};
    }
    if(path==='/admin/id-image'){
      const r=await getDocument(env,token,`gate_entries/${id(body)}`);
      if(!r) fail('not-found','Entry not found.',404);
      if(!Number.isInteger(body.index)||body.index<0||body.index>5||!['front','back'].includes(body.side))fail('invalid-argument','Invalid identification.');
      const adult=entryIds(r.data)[`adult_${body.index}`];
      const storagePath=adult?.[`${body.side}Path`];
      if(adult?.idStatus!=='provided'|| !storagePath)fail('not-found','No ID provided.',404);
      if(!env.SUPABASE_SECRET_KEY)fail('storage-unavailable','ID storage unavailable.',503);
      const response=await fetch(`${env.SUPABASE_URL}/storage/v1/object/authenticated/gate-id-cards/${storagePath.split('/').map(encodeURIComponent).join('/')}`,{headers:{authorization:`Bearer ${env.SUPABASE_SECRET_KEY}`,apikey:env.SUPABASE_SECRET_KEY}});
      if(!response.ok) fail('image-unavailable','ID image is unavailable.',502);
      return new Response(response.body,{headers:{'content-type':response.headers.get('content-type')||'image/jpeg','cache-control':'no-store','x-content-type-options':'nosniff'}});
    }
    if(path==='/admin/report' || path==='/admin/report-reply' || path==='/admin/report-status'){
      const reportId=id(body);
      return withTransaction(env,async({token,transaction})=>{
        assertAdmin(await getDocument(env,token,`users/${claims.sub}`,transaction));
        const r=await getDocument(env,token,`reports/${reportId}`,transaction);if(!r)fail('not-found','Report not found.',404);
        const changes={adminReadAt:new Date()};
        if(path.endsWith('reply')){
          const message=requiredString(body,'message',500);
          const conversation={...(r.data.conversation||{})};
          if(!Object.keys(conversation).length && (r.data.adminReply||r.data.adminResponse)) conversation.legacy={role:'admin',message:r.data.adminResponse||r.data.adminReply,createdAt:r.data.updatedAt||r.data.createdAt};
          conversation[crypto.randomUUID()]={role:'admin',message,createdAt:new Date().toISOString()};
          Object.assign(changes,{conversation,adminReply:message,adminResponse:message,updatedAt:new Date()});
        }
        if(path.endsWith('status')) {if(!['pending','in_progress','resolved'].includes(body.status))fail('invalid-status','Invalid status.');Object.assign(changes,{status:body.status,updatedAt:new Date()});}
        return {writes:[write(env,`reports/${reportId}`,changes,r)],result:{report:{...record(r),message:r.data.message??r.data.description??'',conversation:r.data.conversation??((r.data.adminResponse||r.data.adminReply)?{legacy:{role:'admin',message:r.data.adminResponse||r.data.adminReply,createdAt:r.data.updatedAt||r.data.createdAt}}:{}),...changes}}};
      });
    }
    fail('not-found','Endpoint not found.',404);
  };
}








