// Chrome gives the Services menu a link's text, never its address, hence this extension.

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "open-in-knotchy", title: "Open in Knotchy", contexts: ["link"] });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== "open-in-knotchy" || !info.linkUrl || !tab || tab.id === undefined) return;
  if (!/^https?:\/\//i.test(info.linkUrl)) return;
  const target = "knotchy://open?url=" + encodeURIComponent(info.linkUrl);
  // Hands the URL to the app without leaving the page.
  chrome.tabs.update(tab.id, { url: target });
});
