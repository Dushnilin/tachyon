"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.tachyon.main as main";

function createDashboardContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.DashboardTab.initController();
    return main.DashboardTab.render();
  };

  const originalRender = section.render;
  section.render = function () {
    return originalRender.apply(this, arguments).then((node) => {
      if (node) {
        node.style.overflowAnchor = "none";
        const directDiv = node.querySelector(":scope > .cbi-section-node");
        if (directDiv && directDiv.tagName === "DIV") {
          const semanticSection = document.createElement("section");
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

return baseclass.extend(EntryPoint);
