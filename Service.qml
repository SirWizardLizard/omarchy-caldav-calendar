import QtQuick
import Quickshell
import Quickshell.Io
import "CalendarModel.js" as Model

Item {
  id: root

  property var shell: null
  property string provider: "evolution-data-server"
  property var events: []
  property var calendars: []
  property var cachedEvents: []
  property var cachedCalendars: []
  property var eventsByDay: ({})
  property string status: "idle"
  property string errorMessage: ""
  property string activeStart: ""
  property string activeEnd: ""
  property var pendingSnapshot: null
  property date lastSyncAt: new Date(NaN)
  property string lastSyncText: "Never synced"
  property bool syncing: false
  property int generation: 0
  property string setupStatus: ""
  property string pendingCreateId: ""
  property var pendingUpdateOriginal: null
  property int reminderMinutes: 10
  property string reminderTimeFormat: "12h"
  property var firedReminders: ({})
  property var pendingNotices: []
  property bool remindersReady: false
  readonly property int maxHelperBytes: 8 * 1024 * 1024
  readonly property int maxHelperErrorBytes: 64 * 1024

  signal refreshed()
  signal eventCreated(var event)
  signal eventSaved(bool ok, string message)
  signal setupFinished(bool ok, string message)

  function helperPath() {
    return decodeURIComponent(Qt.resolvedUrl("helper/omarchy-calendar-helper").toString().replace(/^file:\/\//, ""))
  }

  function failMessage(payload, fallback) {
    return Model.plainDisplay((payload && payload.error && payload.error.message) || fallback || "Calendar helper failed", 400)
  }

  function helperText(out, err) {
    var text = String(out || "")
    if (text.length > maxHelperBytes)
      return JSON.stringify({ ok: false, error: { message: "Calendar response was too large." } })
    if (text)
      return text
    var e = String(err || "").trim()
    if (e.length > maxHelperErrorBytes)
      e = e.slice(0, maxHelperErrorBytes)
    if (!e)
      return ""
    return JSON.stringify({ ok: false, error: { message: Model.plainDisplay(e, 400) } })
  }

  function snapshot(start, end, requestedProvider, forceSync) {
    var nextStart = String(start || "")
    var nextEnd = String(end || "")
    var nextProvider = String(requestedProvider || provider || "evolution-data-server")
    if (!nextStart || !nextEnd) return
    activeStart = nextStart
    activeEnd = nextEnd
    provider = nextProvider
    generation += 1
    errorMessage = ""
    if (cachedEvents.length > 0) {
      showActiveRange()
      status = "ready"
    }
    readCache()
    var stale = !isNaN(lastSyncAt.getTime()) && (Date.now() - lastSyncAt.getTime() > 15 * 60 * 1000)
    var shouldSync = forceSync === true || (cachedEvents.length === 0 && !snapshotProc.running) || stale
    if (shouldSync) startLiveSync()
  }

  function showActiveRange() {
    root.calendars = root.cachedCalendars
    root.events = Model.eventsInRange(root.cachedEvents, root.activeStart, root.activeEnd)
    root.eventsByDay = Model.eventsByDay(root.events)
    root.refreshed()
  }

  function applyCache(payload, fromLive) {
    root.cachedCalendars = (payload.calendars || []).slice(0, 200)
    root.cachedEvents = (payload.events || []).slice(0, 8000)
    showActiveRange()
    root.status = "ready"
    root.errorMessage = ""
    root.setupStatus = ""
    if (fromLive) {
      root.lastSyncAt = new Date()
      root.lastSyncText = Qt.formatDateTime(root.lastSyncAt, "MMM d HH:mm")
    } else if (isNaN(root.lastSyncAt.getTime())) {
      root.lastSyncText = "Cached"
    }
    root.checkReminders()
  }

  function readCache() {
    if (cacheProc.running) return
    cacheProc.command = [helperPath(), "snapshot", "--from-cache", "--provider", provider, "--from", activeStart, "--to", activeEnd]
    cacheProc.running = true
  }

  function startLiveSync() {
    if (snapshotProc.running) {
      pendingSnapshot = { start: activeStart, end: activeEnd, provider: provider }
      return
    }
    if (cachedEvents.length === 0) status = "loading"
    syncing = true
    snapshotTimeout.restart()
    snapshotProc.command = [helperPath(), "snapshot", "--provider", provider, "--from", activeStart, "--to", activeEnd]
    snapshotProc.running = true
  }

  function finishCache(text, exitCode) {
    var payload = Model.parseHelperResponse(text)
    if (exitCode === 0 && payload.ok) applyCache(payload, false)
  }

  function finishSnapshot(text, exitCode) {
    snapshotTimeout.stop()
    syncing = false
    var payload = Model.parseHelperResponse(text)
    if (exitCode === 0 && payload.ok) {
      applyCache(payload, true)
    } else if (cachedEvents.length === 0) {
      root.status = "error"
      root.errorMessage = root.failMessage(payload, "Calendar helper failed")
      root.setupStatus = ""
      root.refreshed()
    }
    root.runPendingSnapshot()
  }

  function finishCreate(text, exitCode) {
    var payload = Model.parseOperationResponse(text)
    if (exitCode === 0 && payload.ok) {
      root.confirmPendingCreates(root.pendingCreateId)
      root.status = "ready"
      root.errorMessage = ""
      root.eventCreated(payload.event)
      root.eventSaved(true, "")
      if (root.activeStart && root.activeEnd) root.snapshot(root.activeStart, root.activeEnd, root.provider, true)
    } else {
      root.removePendingCreates(root.pendingCreateId)
      root.status = "error"
      root.errorMessage = root.failMessage(payload, "Calendar helper failed")
      root.eventSaved(false, root.errorMessage)
    }
    root.pendingCreateId = ""
  }

  function finishUpdate(text, exitCode) {
    var payload = Model.parseOperationResponse(text)
    if (exitCode === 0 && payload.ok) {
      if (payload.event) root.mergeEvent(payload.event)
      if (root.pendingUpdateOriginal && payload.event && root.pendingUpdateOriginal.calendarId && payload.event.calendarId && root.pendingUpdateOriginal.calendarId !== payload.event.calendarId) {
        root.removeEventsByUid(root.pendingUpdateOriginal.uid, root.pendingUpdateOriginal.calendarId)
      }
      root.status = "ready"
      root.errorMessage = ""
      root.eventSaved(true, "")
      if (root.pendingUpdateOriginal && payload.event && root.pendingUpdateOriginal.calendarId !== payload.event.calendarId) root.readCache()
      else if (root.activeStart && root.activeEnd) root.snapshot(root.activeStart, root.activeEnd, root.provider, true)
    } else {
      if (root.pendingUpdateOriginal) root.mergeEvent(root.pendingUpdateOriginal)
      root.status = "error"
      root.errorMessage = root.failMessage(payload, "Calendar helper failed")
      root.eventSaved(false, root.errorMessage)
    }
    root.pendingUpdateOriginal = null
  }

  function finishSetup(text, exitCode) {
    setupWatchdog.running = false
    var payload = Model.parseOperationResponse(text)
    if (exitCode === 0 && payload.ok) {
      root.status = "ready"
      root.errorMessage = ""
      root.setupStatus = ""
      root.setupFinished(true, "Calendar source added.")
      root.snapshot(root.activeStart || new Date().toISOString(), root.activeEnd || new Date(Date.now() + 31 * 86400000).toISOString(), root.provider, true)
    } else {
      root.status = "error"
      root.setupStatus = ""
      root.errorMessage = root.failMessage(payload, "Calendar setup failed")
      root.setupFinished(false, root.errorMessage)
    }
  }

  function runPendingSnapshot() {
    if (!pendingSnapshot) return
    var pending = pendingSnapshot
    pendingSnapshot = null
    snapshot(pending.start, pending.end, pending.provider, true)
  }

  function eventsForDay(key) {
    return Model.eventsForDay(eventsByDay, key)
  }

  function eventCountForDay(key) {
    return Model.eventCountForDay(eventsByDay, key)
  }

  function defaultWritableCalendarId() {
    for (var i = 0; i < calendars.length; i++) {
      if (calendars[i] && calendars[i].readonly !== true) return calendars[i].id
    }
    return calendars.length > 0 && calendars[0] ? calendars[0].id : ""
  }

  function calendarById(calendarId) {
    for (var i = 0; i < calendars.length; i++) {
      if (calendars[i] && calendars[i].id === calendarId) return calendars[i]
    }
    return null
  }

  function optimisticEvent(calendarId, id, uid, title, startIso, endIso, location, description, eventStatus, allDay) {
    var calendar = calendarById(calendarId) || {}
    return {
      id: id,
      uid: uid || id,
      rid: "",
      calendarId: calendarId,
      calendarName: calendar.name || "Calendar",
      calendarColor: calendar.color || "#8aadf4",
      title: String(title || "(No title)"),
      location: String(location || ""),
      description: String(description || ""),
      start: String(startIso || ""),
      end: String(endIso || startIso || ""),
      allDay: allDay === true,
      status: String(eventStatus || "confirmed"),
      provider: provider,
      source: calendar.source || "Evolution Data Server"
    }
  }

  function mergeEvent(event) {
    if (!event || !event.id) return
    var next = []
    var replaced = false
    var source = cachedEvents.length ? cachedEvents : events
    for (var i = 0; i < source.length; i++) {
      if (source[i] && source[i].id === event.id) {
        next.push(event)
        replaced = true
      } else {
        next.push(source[i])
      }
    }
    if (!replaced) next.push(event)
    cachedEvents = Model.normalizeEvents(next)
    showActiveRange()
  }

  function replaceEvent(oldId, event) {
    if (!event || !event.id) return
    var next = []
    var replaced = false
    var source = cachedEvents.length ? cachedEvents : events
    for (var i = 0; i < source.length; i++) {
      if (source[i] && (source[i].id === oldId || source[i].id === event.id)) {
        if (!replaced) next.push(event)
        replaced = true
      } else {
        next.push(source[i])
      }
    }
    if (!replaced) next.push(event)
    cachedEvents = Model.normalizeEvents(next)
    showActiveRange()
  }

  function removeEvent(eventId) {
    var next = []
    var source = cachedEvents.length ? cachedEvents : events
    for (var i = 0; i < source.length; i++) {
      if (!source[i] || source[i].id !== eventId) next.push(source[i])
    }
    cachedEvents = Model.normalizeEvents(next)
    showActiveRange()
  }

  function removePendingCreates(prefix) {
    if (!prefix) return
    cachedEvents = Model.normalizeEvents((cachedEvents.length ? cachedEvents : events).filter(function(event) {
      return !event || String(event.id || "").indexOf(prefix) !== 0
    }))
    showActiveRange()
  }

  function removeEventsByUid(uid, calendarId) {
    cachedEvents = Model.normalizeEvents((cachedEvents.length ? cachedEvents : events).filter(function(event) {
      return !event || event.uid !== uid || (calendarId && event.calendarId !== calendarId)
    }))
    showActiveRange()
  }

  function confirmPendingCreates(prefix) {
    if (!prefix) return
    cachedEvents = Model.normalizeEvents((cachedEvents.length ? cachedEvents : events).map(function(event) {
      if (!event || String(event.id || "").indexOf(prefix) !== 0) return event
      var next = {}
      Object.keys(event).forEach(function(key) { next[key] = event[key] })
      next.status = "confirmed"
      return next
    }))
    showActiveRange()
  }

  function deleteEvent(event, scope) {
    if (!event || event.status === "saving" || !event.uid || String(event.id || "").indexOf("omarchy-calendar-pending-") === 0) return
    var deleteScope = String(scope || (event.rid || event.recurring ? "this" : "all"))
    provider = "evolution-data-server"
    errorMessage = ""
    if (deleteScope === "all") {
      var kept = []
      var source = cachedEvents.length ? cachedEvents : events
      for (var i = 0; i < source.length; i++) {
        if (!source[i] || source[i].uid !== event.uid || source[i].calendarId !== event.calendarId) kept.push(source[i])
      }
      cachedEvents = Model.normalizeEvents(kept)
      showActiveRange()
    } else {
      removeEvent(event.id)
    }
    if (deleteProc.running) deleteProc.running = false
    deleteProc.command = [
      helperPath(), "delete-event",
      "--provider", provider,
      "--calendar-id", String(event.calendarId || defaultWritableCalendarId()),
      "--uid", String(event.uid || ""),
      "--rid", deleteScope === "all" ? "" : String(event.rid || ""),
      "--scope", deleteScope
    ]
    deleteProc.running = true
  }

  function createEvent(calendarId, title, startIso, endIso, location, description, repeat, allDay, meetingUrl, meetingKind) {
    provider = "evolution-data-server"
    status = "saving"
    errorMessage = ""
    if (createProc.running) createProc.running = false
    pendingCreateId = "omarchy-calendar-pending-" + Date.now()
    var pending = optimisticEvent(calendarId || defaultWritableCalendarId(), pendingCreateId, "", title, startIso, endIso, location, description, "saving", allDay)
    var expanded = Model.expandRecurringEvent(pending, repeat, activeStart, activeEnd)
    if (!expanded.length) expanded = [pending]
    for (var i = 0; i < expanded.length; i++) {
      expanded[i].id = pendingCreateId + ":" + i
      expanded[i].status = "saving"
      mergeEvent(expanded[i])
    }
    createProc.command = [
      helperPath(), "create-event",
      "--provider", provider,
      "--calendar-id", String(calendarId || defaultWritableCalendarId()),
      "--title", String(title || "(No title)"),
      "--from", String(startIso || ""),
      "--to", String(endIso || ""),
      "--location", String(location || ""),
      "--description", String(description || ""),
      "--rrule", String(repeat || "never"),
      "--meeting-url", String(meetingUrl || ""),
      "--meeting-kind", String(meetingKind || "none")
    ]
    if (allDay) createProc.command.push("--all-day")
    createProc.running = true
  }

  function updateEvent(event, title, startIso, endIso, location, description, scope, allDay, calendarId, meetingUrl, meetingKind) {
    if (!event || event.status === "saving" || !event.uid || String(event.id || "").indexOf("omarchy-calendar-pending-") === 0) {
      root.eventSaved(false, "Could not save the event.")
      return
    }
    var editScope = String(scope || (event.rid || event.recurring ? "this" : "all"))
    provider = "evolution-data-server"
    status = "saving"
    errorMessage = ""
    if (updateProc.running) updateProc.running = false
    pendingUpdateOriginal = event
    var destId = String(calendarId || event.calendarId || defaultWritableCalendarId())
    var next = optimisticEvent(destId, event.id, event.uid, title, startIso, endIso, location, description, "saving", allDay)
    next.rid = event.rid || ""
    next.recurring = event.recurring === true
    mergeEvent(next)
    updateProc.command = [
      helperPath(), "update-event",
      "--provider", provider,
      "--calendar-id", String(event.calendarId || defaultWritableCalendarId()),
      "--to-calendar-id", destId,
      "--uid", String(event.uid || ""),
      "--rid", String(event.rid || ""),
      "--scope", editScope,
      "--title", String(title || "(No title)"),
      "--from", String(startIso || ""),
      "--to", String(endIso || ""),
      "--location", String(location || ""),
      "--description", String(description || ""),
      "--meeting-url", String(meetingUrl || ""),
      "--meeting-kind", String(meetingKind || "none")
    ]
    if (allDay) updateProc.command.push("--all-day")
    updateProc.running = true
  }

  function applyCalendarAppearance(names, colors) {
    names = names || {}
    colors = colors || {}
    var nextCalendars = []
    for (var i = 0; i < cachedCalendars.length; i++) {
      var calendar = cachedCalendars[i]
        nextCalendars.push({
        id: calendar.id,
        name: names[calendar.id] || calendar.name,
        color: colors[calendar.id] || calendar.color,
        provider: calendar.provider,
        host: calendar.host || "",
        source: calendar.source,
        readonly: calendar.readonly
      })
    }
    var nextEvents = []
    for (var j = 0; j < cachedEvents.length; j++) {
      var event = cachedEvents[j]
      nextEvents.push({
        id: event.id,
        uid: event.uid,
        rid: event.rid,
        calendarId: event.calendarId,
        calendarName: names[event.calendarId] || event.calendarName,
        calendarColor: colors[event.calendarId] || event.calendarColor,
        title: event.title,
        location: event.location,
        description: event.description,
        start: event.start,
        end: event.end,
        allDay: event.allDay,
        status: event.status,
        provider: event.provider,
        source: event.source
      })
    }
    cachedCalendars = nextCalendars
    cachedEvents = nextEvents
    showActiveRange()
  }

  function removeCalendar(calendarId) {
    var id = String(calendarId || "")
    if (!id) return
    cachedCalendars = cachedCalendars.filter(function(calendar) { return calendar && calendar.id !== id })
    cachedEvents = cachedEvents.filter(function(event) { return event && event.calendarId !== id })
    showActiveRange()
    if (removeProc.running) removeProc.running = false
    removeProc.command = [helperPath(), "remove-calendar", "--provider", provider, "--calendar-id", id]
    removeProc.running = true
  }

  function setReminderMinutes(minutes, timeFormat) {
    reminderMinutes = Model.normalizedReminderMinutes(minutes)
    if (timeFormat) reminderTimeFormat = String(timeFormat) === "24h" ? "24h" : "12h"
    saveReminderState()
    checkReminders()
  }

  function applyReminderState(payload) {
    reminderMinutes = Model.normalizedReminderMinutes(payload && payload.minutes)
    var fired = {}
    var keys = payload && payload.fired ? payload.fired : []
    for (var i = 0; i < keys.length; i++) fired[String(keys[i])] = true
    firedReminders = Model.pruneFiredKeys(fired)
    remindersReady = true
    if (!activeStart) {
      var start = new Date()
      start.setHours(0, 0, 0, 0)
      var end = new Date(start)
      end.setDate(end.getDate() + 3)
      snapshot(start.toISOString(), end.toISOString(), provider, false)
    }
    checkReminders()
  }

  function saveReminderState() {
    if (reminderSaveProc.running) return
    reminderSaveProc.secret = JSON.stringify({ minutes: reminderMinutes, fired: Object.keys(firedReminders) })
    reminderSaveProc.command = [helperPath(), "reminders-save"]
    reminderSaveProc.stdinEnabled = true
    reminderSaveProc.running = true
  }

  function checkReminders() {
    if (!remindersReady || reminderMinutes <= 0) return
    firedReminders = Model.pruneFiredKeys(firedReminders)
    var due = Model.dueReminders(cachedEvents, reminderMinutes, firedReminders)
    if (!due.length) return
    var next = Model.copyMap(firedReminders)
    var queue = pendingNotices.slice()
    for (var i = 0; i < due.length; i++) {
      next[due[i].key] = true
      queue.push(due[i].event)
    }
    firedReminders = next
    pendingNotices = queue
    saveReminderState()
    flushNotices()
  }

  function flushNotices() {
    if (notifyProc.running || pendingNotices.length === 0) return
    var event = pendingNotices[0]
    pendingNotices = pendingNotices.slice(1)
    var meeting = Model.eventMeeting(event)
    var command = ["omarchy-notification-send", "--app-name", "CalDav Calendar", "-u", "normal", "-g", "󰃭"]
    var url = meeting && meeting.url ? String(meeting.url) : ""
    if (/^https?:\/\//i.test(url)) command.push("--exec", "xdg-open '" + url.replace(/'/g, "") + "'")
    command.push(String(event.title || "(No title)"))
    var body = Model.reminderBody(event, reminderTimeFormat)
    if (body) command.push(body)
    notifyProc.command = command
    notifyProc.running = true
  }

  function bootReminders() {
    if (!anchorProc.running) {
      anchorProc.command = [helperPath(), "ensure-center-anchor", "--title", "sirwizardlizard.calendar"]
      anchorProc.running = true
    }
    if (reminderStateProc.running) return
    reminderStateProc.command = [helperPath(), "reminders-state"]
    reminderStateProc.running = true
  }

  function updateCalendars(entries, names, colors) {
    applyCalendarAppearance(names, colors)
    if (calendarsProc.running) calendarsProc.running = false
    calendarsProc.secret = JSON.stringify({ calendars: entries || [] })
    calendarsProc.command = [helperPath(), "update-calendars", "--provider", provider]
    calendarsProc.stdinEnabled = true
    calendarsProc.running = true
  }


  function createLocalCalendar(displayName) {
    provider = "evolution-data-server"
    status = "saving"
    setupStatus = "Creating local calendar..."
    errorMessage = ""
    if (setupProc.running) setupProc.running = false
    setupProc.secret = ""
    setupProc.command = [helperPath(), "create-local-calendar", "--provider", provider, "--title", String(displayName || "Calendar")]
    setupProc.stdinEnabled = true
    setupProc.running = true
    setupWatchdog.restart()
  }

  function setupCalDav(displayName, url, username, password) {
    provider = "evolution-data-server"
    status = "saving"
    setupStatus = "Adding calendar source..."
    errorMessage = ""
    if (setupProc.running) setupProc.running = false
    setupProc.secret = JSON.stringify({
      displayName: String(displayName || "Calendar"),
      url: String(url || ""),
      username: String(username || ""),
      password: String(password || "")
    })
    setupProc.command = [helperPath(), "setup-caldav", "--provider", provider]
    setupProc.stdinEnabled = true
    setupProc.running = true
    setupWatchdog.restart()
  }

  Process {
    id: cacheProc
    running: false

    stdout: StdioCollector { id: cacheOut; waitForEnd: true }
    stderr: StdioCollector { id: cacheErr; waitForEnd: true }

    onExited: function(exitCode) {
      root.finishCache(root.helperText(cacheOut.text, cacheErr.text), exitCode)
    }
  }

  Process {
    id: snapshotProc
    running: false

    stdout: StdioCollector { id: snapshotOut; waitForEnd: true }
    stderr: StdioCollector { id: snapshotErr; waitForEnd: true }

    onExited: function(exitCode) {
      root.finishSnapshot(root.helperText(snapshotOut.text, snapshotErr.text), exitCode)
    }
  }

  Process {
    id: createProc
    running: false

    stdout: StdioCollector { id: createOut; waitForEnd: true }
    stderr: StdioCollector { id: createErr; waitForEnd: true }

    onExited: function(exitCode) {
      root.finishCreate(root.helperText(createOut.text, createErr.text), exitCode)
    }
  }

  Process {
    id: deleteProc
    running: false
    stdout: StdioCollector { id: deleteOut; waitForEnd: true }
    stderr: StdioCollector { id: deleteErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var payload = Model.parseOperationResponse(root.helperText(deleteOut.text, deleteErr.text))
        root.errorMessage = root.failMessage(payload, "Could not delete event.")
        root.status = "error"
      }
    }
  }

  Process {
    id: updateProc
    running: false

    stdout: StdioCollector { id: updateOut; waitForEnd: true }
    stderr: StdioCollector { id: updateErr; waitForEnd: true }

    onExited: function(exitCode) {
      root.finishUpdate(root.helperText(updateOut.text, updateErr.text), exitCode)
    }
  }

  Process {
    id: removeProc
    running: false
    stdout: StdioCollector { id: removeOut; waitForEnd: true }
    stderr: StdioCollector { id: removeErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.readCache()
    }
  }

  Process {
    id: calendarsProc
    property string secret: ""
    running: false
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
    }

    stdout: StdioCollector { id: calendarsOut; waitForEnd: true }
    stderr: StdioCollector { id: calendarsErr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) root.readCache()
    }
  }

  Process {
    id: setupProc
    property string secret: ""
    running: false
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
    }

    stdout: StdioCollector { id: setupOut; waitForEnd: true }
    stderr: StdioCollector { id: setupErr; waitForEnd: true }

    onExited: function(exitCode) {
      root.finishSetup(root.helperText(setupOut.text, setupErr.text), exitCode)
    }
  }

  Timer {
    id: setupWatchdog
    interval: 120000
    repeat: false
    onTriggered: {
      if (!setupProc.running) return
      setupProc.running = false
      root.status = "error"
      root.setupStatus = ""
      root.errorMessage = "Calendar setup timed out. Check the server URL and that the server is reachable."
      root.setupFinished(false, root.errorMessage)
    }
  }

  Process {
    id: reminderStateProc
    running: false
    stdout: StdioCollector { id: reminderStateOut; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = Model.parseOperationResponse(root.helperText(reminderStateOut.text, ""))
      root.applyReminderState(exitCode === 0 && payload.ok ? payload : { minutes: 10, fired: [] })
    }
  }

  Process {
    id: reminderSaveProc
    property string secret: ""
    running: false
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: notifyProc
    running: false
    onExited: root.flushNotices()
  }

  Process {
    id: anchorProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.checkReminders()
  }

  Component.onCompleted: root.bootReminders()

  Timer {
    id: snapshotTimeout
    interval: 60000
    repeat: false
    onTriggered: {
      if (!snapshotProc.running) return
      snapshotProc.running = false
      root.syncing = false
      if (root.cachedEvents.length === 0) {
        root.status = "error"
        root.errorMessage = "Calendar sync timed out. Try Sync now again."
      } else {
        root.status = "ready"
      }
      root.setupStatus = ""
      root.refreshed()
      root.runPendingSnapshot()
    }
  }
}
