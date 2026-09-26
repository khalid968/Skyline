// Board 41. Picks the tab for this device, then fills links, sizes and
// checksums from the published release. No cookies, no storage, no tracking.
(function () {
  var tabs = ['android', 'ios', 'windows'];
  var release = null;

  function show(name) {
    tabs.forEach(function (t) {
      document.getElementById('tab-' + t).setAttribute('aria-selected', String(t === name));
      document.getElementById('panel-' + t).hidden = t !== name;
    });
    var item = release && release[name];
    var sum = document.getElementById('checksum');
    if (name === 'ios') sum.textContent = 'Installed from Apple: nothing to check.';
    else sum.textContent = item && item.sha256 ? 'SHA-256 ' + item.sha256.replace(/(.{4})/g, '$1 ').trim() : '—';
  }

  function mb(bytes) {
    return Math.round(bytes / 1048576) + ' MB';
  }

  function fill(latest) {
    release = latest;
    document.getElementById('unavailable').hidden = !!latest;
    [
      ['android', 'Android 8 or newer'],
      ['windows', 'Windows 10 or 11 · signed installer'],
      ['ios', null],
    ].forEach(function (p) {
      var link = document.getElementById(p[0] + '-link');
      var item = latest && latest[p[0]];
      if (item && item.url) {
        link.href = item.url;
        link.removeAttribute('aria-disabled');
      } else {
        link.removeAttribute('href');
        link.setAttribute('aria-disabled', 'true');
      }
      // Until the organization has a code-signing certificate, a Windows
      // installer published by hand is marked "signed": false, and the page
      // says what Windows will show instead of "stop if it's unknown".
      var unsigned = p[0] === 'windows' && item && item.signed === false;
      if (p[1] && item) {
        document.getElementById(p[0] + '-meta').textContent =
          'Version ' + latest.version + (item.size ? ' · ' + mb(item.size) : '') + ' · ' +
          (unsigned ? 'Windows 10 or 11 · installer not signed yet' : p[1]);
      }
      if (unsigned) {
        document.getElementById('windows-card').textContent =
          'This installer isn’t signed yet, so Windows will show “Windows protected your PC” ' +
          'and “Unknown publisher”. That is expected for now: choose More info, then Run anyway. ' +
          'If you want to be sure the download is intact, compare its SHA-256 with the one below. ' +
          'If anything else looks wrong, don’t install it: tell your administrator.';
      }
    });
  }

  var ua = navigator.userAgent;
  var start = /iPhone|iPad|iPod/.test(ua) ? 'ios' : /Windows/.test(ua) ? 'windows' : 'android';
  tabs.forEach(function (t) {
    document.getElementById('tab-' + t).addEventListener('click', function () {
      show(t);
    });
  });
  show(start);

  fetch('/api/app/releases', { credentials: 'omit' })
    .then(function (r) {
      return r.ok ? r.json() : { latest: null };
    })
    .then(function (j) {
      fill(j.latest);
      show(start);
    })
    .catch(function () {
      fill(null);
    });
})();
