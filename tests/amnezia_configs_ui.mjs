import fs from 'fs';
import vm from 'vm';
import { strict as assert } from 'assert';
import { TextEncoder } from 'util';
const source=fs.readFileSync(new URL('../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js',import.meta.url),'utf8');
let supported=true;
const options={};
const context={E:(tag,attrs,text)=>({tag,attrs,text}),TextEncoder, btoa:value=>Buffer.from(value,'binary').toString('base64'),
 atob:value=>Buffer.from(value,'base64').toString('binary'), _:text=>text,
 main:{supportsVpnUrl:()=>supported,validateProxyUrl:link=>({valid:link.startsWith('vpn://')})},
 normalizeDynamicListItems:value=>Array.isArray(value)?value:value?[value]:[],
 form:{TextValue:'TextValue'}, ButtonAddSettingsDynamicList:'NamedConfigs',
 outboundNameSourceOptions:new Map(), refreshDashboardFilterChoiceWidgets(){},
 showAmneziaConfigSettingsModal(){},
 section:{taboption(tab,type,name,title,description){return options[name]={tab,type,name,title,description,
   depends(){},isActive(){return true;},render(){return null;}};}}};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function parseAmneziaConfig('),source.indexOf('function showAmneziaConfigSettingsModal('))+
 source.slice(source.indexOf('function validateAmneziaConfigsBeforeSave('),source.indexOf('function showOutboundJsonSettingsModal(')),context);
const start=source.indexOf('  o = section.taboption(',source.indexOf('  outboundNameSourceOptions.set("selector_proxy_links", o);'));
const end=source.indexOf('  outboundNameSourceOptions.set("selector_amnezia_configs", o);',start);
vm.runInContext('let o;'+source.slice(start,end)+'outboundNameSourceOptions.set("selector_amnezia_configs",o);',context);
const option=options.selector_amnezia_configs;
assert.equal(option.type,'NamedConfigs');assert.equal(option.retain,true);
assert.equal(option.isActive(),true);supported=false;assert.equal(option.isActive(),false);supported=true;
const key=Buffer.alloc(32,1).toString('base64');
const base=`[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\n[Peer]\nPublicKey = ${key}\nEndpoint = 192.0.2.1:51820\n`;
for(const fields of ['Jc = 4\nH1 = 100\nI1 = <b 0x01>\n','S3 = 40\nS4 = 50\nH1 = 100-200\n',`HeaderProtectionKey = ${key}\nRandomTrailers = on\nDisableCookies = false\n`]) {
 const config=base.replace('[Peer]',fields+'[Peer]'), value=JSON.stringify({name:'Тест AWG',config});
 assert.equal(option.validate('test',value),true);
 assert.equal(option.renderListItemLabel('test',value).text,'Тест AWG');
 assert.equal(option.renderListItemLabel('test',value).attrs.class,'fkp-dynlist-label');
 const link=context.amneziaConfigLink('Тест AWG',config);
 assert.equal(Buffer.from(link.slice(6),'base64').toString('utf8'),'# Тест AWG\n'+config);
 assert(!option.renderListItemLabel('test',value).text.includes(key));
}
for(const fields of ['Jc = 1-2\n','H1 = 200-100\n','S4 = -1\n','MTU = 10\n','HeaderProtectionKey = bad\n','RandomTrailers = maybe\n']) {
 assert.notEqual(option.validate('test',JSON.stringify({name:'Bad',config:base.replace('[Peer]',fields+'[Peer]')})),true);
}
for(const name of ['', 'bad\nname', 'a'.repeat(201), 'я'.repeat(101)])
 assert.notEqual(context.validateAmneziaConfig(name,base),true);
assert.equal(context.parseAmneziaConfig('invalid'),null);
assert.equal(context.amneziaConfigTextForSave('line\r\n','line\n'),'line\r\n');
assert.equal(context.amneziaConfigTextForSave('line\r\n','edited\n'),'edited\n');
assert(source.includes('style: "display:none!important"'));
assert.notEqual(context.validateAmneziaConfig('Large',base+'#'.repeat(65536)),true);
assert.notEqual(context.validateAmneziaConfigsBeforeSave('test',[JSON.stringify({name:'Same',config:base}),JSON.stringify({name:'Same',config:base})]),true);
assert.equal(option.renderListItemLabel('test','invalid').text,'Invalid Amnezia .conf file');
const ru=fs.readFileSync(new URL('../luci-app-tachyon/po/ru/tachyon.po',import.meta.url),'utf8');
for(const title of [option.title,option.description]) assert(ru.includes('msgid '+JSON.stringify(title)+'\nmsgstr "') && !ru.includes('msgid '+JSON.stringify(title)+'\nmsgstr ""'));
assert(source.indexOf('"selector_proxy_links",\n    _("Connection URL")') < start);
assert(end < source.indexOf('"selector_proxy_links_text",',end));
console.log('PASS: named Amnezia UI, UTF-8, AWG fields, size limits, duplicate names, capability gate and localization');
