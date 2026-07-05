// veejr service worker: surfaces content-free push notifications.
// The payload only ever says who sent something and what kind it is —
// the content itself stays on the sender's instance until requested.

self.addEventListener("push", (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_) {}

  event.waitUntil(
    self.registration.showNotification(data.title || "veejr", {
      body: data.body || "Something encrypted awaits you.",
      icon: "/images/logo.svg",
      tag: "veejr-push",
      data: {url: data.url || "/messages"},
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/messages"
  event.waitUntil(
    clients.matchAll({type: "window", includeUncontrolled: true}).then((windows) => {
      for (const client of windows) {
        if ("focus" in client) return client.focus()
      }
      return clients.openWindow(url)
    })
  )
})
