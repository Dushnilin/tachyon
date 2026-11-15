/* eslint-disable @typescript-eslint/no-explicit-any */
'use strict';
'require baseclass';
'require form';
'require ui';
'require uci';
'require fs';
'require view.tachyon.main as main';

declare const main: any;

function createDashboardContent(section: any): void {
  const o = section.option(form.DummyValue, '_mount_node');
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.DashboardTab.initController();
    return main.DashboardTab.render();
  };

  const originalRender = section.render;
  section.render = function (...args: any[]) {
    return originalRender.apply(this, args).then((node: HTMLElement | null) => {
      if (node) {
        node.style.overflowAnchor = 'none';
        const directDiv = node.querySelector(':scope > .cbi-section-node');
        if (directDiv && directDiv.tagName === 'DIV') {
          const semanticSection = document.createElement('section');
          semanticSection.className = directDiv.className;
          if (directDiv.id) semanticSection.id = directDiv.id;
          while (directDiv.firstChild) {
            semanticSection.appendChild(directDiv.firstChild);
          }
          directDiv.replaceWith(semanticSection);
        }
      }
      return node;
    });
  };
}

const EntryPoint = {
  createDashboardContent,
};

export default baseclass.extend(EntryPoint);
