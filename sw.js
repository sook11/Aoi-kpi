/* AOI KPI — Service Worker: รับแจ้งเตือนเด้ง (แชตใหม่ / สินค้าใหม่) แม้ปิดแอปหรือปิดหน้าจอ */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: "AOI KPI", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "AOI KPI", {
    body: d.body || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    tag: d.tag || undefined,
    renotify: true,
    vibrate: [120, 60, 120],
    data: { url: d.url || "./" }
  }));
});

self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (c.url.indexOf(self.registration.scope) === 0 && "focus" in c) { c.postMessage({ open: url }); return c.focus(); }
    }
    return self.clients.openWindow(url);
  }));
});

/* อัปเดต 200: ใช้งานแบบออฟไลน์ (จอทีวีแผนก)
   - หน้าแอป/ไฟล์ของเว็บเอง: ดึงจากเน็ตก่อน ถ้าไม่มีเน็ตใช้สำเนาล่าสุดในเครื่อง
   - ไลบรารีจาก CDN และรูป/สื่อ: ใช้สำเนาในเครื่องก่อน (ไม่ต้องโหลดซ้ำ) */
var SHELL = "aoi-shell-v1", MEDIA = "aoi-media-v1";
self.addEventListener("fetch", function (e) {
  var r = e.request;
  if (r.method !== "GET" || r.headers.get("range")) return;
  var u = new URL(r.url);
  if (u.origin === self.location.origin) {
    if (/\/sw\.js$/.test(u.pathname)) return;
    var key = u.origin + u.pathname;
    e.respondWith(fetch(r).then(function (res) {
      if (res && res.ok && res.type === "basic") { var c = res.clone(); caches.open(SHELL).then(function (ca) { ca.put(key, c); }); }
      return res;
    }).catch(function () {
      return caches.open(SHELL).then(function (ca) { return ca.match(key); }).then(function (m) { return m || Response.error(); });
    }));
    return;
  }
  var cdn = /(^|\.)cdn\.jsdelivr\.net$|(^|\.)cdnjs\.cloudflare\.com$/.test(u.hostname);
  var img = r.destination === "image";
  if (!cdn && !img) return;
  var keep = cdn || /base44\.(app|com)$/.test(u.hostname) || /\/storage\/v1\/object\/public\/tv-media\//.test(u.pathname);
  var store = cdn ? SHELL : MEDIA;
  e.respondWith(caches.open(store).then(function (ca) {
    return ca.match(r.url).then(function (m) {
      if (m) return m;
      return fetch(r).then(function (res) { if (keep && res && (res.ok || res.type === "opaque")) ca.put(r.url, res.clone()); return res; });
    });
  }));
});
