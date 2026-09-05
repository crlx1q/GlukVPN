/* Old bookmarks use the single maintained authentication UI. */
(function () {
  var url = new URL(location.href);
  var english = /^\/en\//.test(url.pathname);
  var mode = /\/recover(?:\/|$)/.test(url.pathname) ? 'recover' : 'register';
  url.pathname = (english ? '/en/' : '/') + 'login/';
  url.searchParams.set('mode', mode);
  location.replace(url.pathname + url.search + url.hash);
})();
