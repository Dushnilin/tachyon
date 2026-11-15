/* eslint-disable @typescript-eslint/no-explicit-any */
'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.tachyon.main as main';

declare const main: any;

function createUpdatesContent(section: any): void {
  const o = section.option(form.DummyValue, '_mount_node');
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.UpdatesTab.initController();
    return main.UpdatesTab.render();
  };
}

const EntryPoint = {
  createUpdatesContent,
};

export default baseclass.extend(EntryPoint);
