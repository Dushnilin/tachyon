/* eslint-disable @typescript-eslint/no-explicit-any */
'use strict';
'require baseclass';
'require form';
'require view.tachyon.local_devices as localDevices';
'require view.tachyon.main as main';

declare const localDevices: any;
declare const main: any;

function createMonitoringContent(section: any): void {
  const o = section.option(form.DummyValue, '_mount_node');
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.MonitoringTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return main.MonitoringTab.render();
  };
}

const EntryPoint = {
  createMonitoringContent,
};

export default baseclass.extend(EntryPoint);
