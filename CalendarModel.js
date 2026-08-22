function pad2(value) {
  return String(value).padStart(2, '0')
}

var MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
var SHORT_MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
var WEEKDAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

function dateKey(year, month, day) {
  if (!isFinite(year) || !isFinite(month) || !isFinite(day)) return ''
  return [year, pad2(month + 1), pad2(day)].join('-')
}

function keyForDate(date) {
  if (!date || isNaN(date.getTime())) return ''
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function dateFromKey(key, fallback) {
  var parts = String(key || '').split('-').map(function(part) { return parseInt(part, 10) })
  if (parts.length === 3 && parts.every(function(part) { return isFinite(part) })) {
    if (parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) return fallback !== undefined ? fallback : new Date()
    var date = new Date(parts[0], parts[1] - 1, parts[2], 0, 0, 0, 0)
    if (!isNaN(date.getTime()) && date.getFullYear() === parts[0] && date.getMonth() === parts[1] - 1 && date.getDate() === parts[2]) return date
  }
  return fallback !== undefined ? fallback : new Date()
}

function parseDateTime(value) {
  var timestamp = Date.parse(String(value || ''))
  return isNaN(timestamp) ? null : new Date(timestamp)
}

function localDateKeyFromIso(value) {
  var date = parseDateTime(value)
  return date ? keyForDate(date) : ''
}

var MEETING_PATTERNS = [
  { provider: 'zoom', match: /(?:https?:\/\/)?(?:[\w.-]+\.)?zoom\.us\/[^\s<>"']+/i },
  { provider: 'meet', match: /(?:https?:\/\/)?meet\.google\.com\/[^\s<>"']+/i },
  { provider: 'teams', match: /(?:https?:\/\/)?teams\.(?:microsoft|live)\.com\/[^\s<>"']+/i }
]

function normalizeMeetingUrl(text) {
  var raw = String(text || '').trim()
  if (!raw) return ''
  return /^https?:\/\//i.test(raw) ? raw : ('https://' + raw.replace(/^\/+/, ''))
}

function meetingFromText(text) {
  var blob = String(text || '')
  for (var i = 0; i < MEETING_PATTERNS.length; i++) {
    var found = blob.match(MEETING_PATTERNS[i].match)
    if (!found) continue
    var url = found[0].replace(/[.,);]+$/, '')
    return { url: normalizeMeetingUrl(url), provider: MEETING_PATTERNS[i].provider }
  }
  return { url: '', provider: '' }
}

function eventMeeting(event) {
  var raw = event || {}
  var stored = meetingFromText(raw.meetingUrl)
  if (stored.url) return stored
  return meetingFromText([raw.location, raw.description, raw.conference].filter(Boolean).join('\n'))
}

function meetingProviderLabel(provider) {
  if (provider === 'zoom') return 'Zoom'
  if (provider === 'meet') return 'Google Meet'
  if (provider === 'teams') return 'Teams'
  return 'Meeting'
}

function normalizedReminderMinutes(value) {
  var minutes = parseInt(value, 10)
  if (minutes === 0) return 0
  if (minutes === 5 || minutes === 10 || minutes === 15 || minutes === 30) return minutes
  return 10
}

function reminderKey(event, minutes) {
  var item = event || {}
  return [String(item.uid || item.id || ''), String(item.start || ''), String(minutes)].join('|')
}

function reminderDue(event, minutes, nowMs) {
  if (!event || event.allDay === true) return false
  var lead = normalizedReminderMinutes(minutes)
  if (lead <= 0) return false
  var start = Date.parse(String(event.start || ''))
  if (isNaN(start)) return false
  var now = nowMs === undefined ? Date.now() : nowMs
  return now >= start - lead * 60 * 1000 && now < start
}

function dueReminders(events, minutes, fired, nowMs) {
  var lead = normalizedReminderMinutes(minutes)
  if (lead <= 0) return []
  var seen = fired || {}
  var result = []
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (!reminderDue(event, lead, nowMs)) continue
    var key = reminderKey(event, lead)
    if (seen[key]) continue
    result.push({ key: key, event: event })
  }
  return result
}

function reminderBody(event, format) {
  var lines = []
  var time = formatTime(event && event.start, false, format || '12h')
  if (time) lines.push('Starts at ' + time)
  var meeting = eventMeeting(event)
  if (meeting.url) lines.push('Join ' + meetingProviderLabel(meeting.provider))
  return lines.join('\n')
}

function pruneFiredKeys(fired, nowMs) {
  var now = nowMs === undefined ? Date.now() : nowMs
  var next = {}
  var source = fired || {}
  for (var key in source) {
    var start = Date.parse(String(key.split('|')[1] || ''))
    if (!isNaN(start) && start >= now - 24 * 60 * 60 * 1000) next[key] = true
  }
  return next
}

function plainDisplay(value, maxLen) {
  var text = String(value == null ? '' : value)
  text = text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
  text = text.replace(/<[^>]*>/g, '')
  var limit = maxLen || 400
  if (text.length > limit) text = text.slice(0, limit)
  return text
}

function normalizedEvent(raw) {
  var event = raw || {}
  var start = String(event.start || '')
  var end = String(event.end || start)
  var meeting = eventMeeting(event)
  return {
    id: String(event.id || event.uid || ''),
    uid: String(event.uid || ''),
    rid: String(event.rid || ''),
    calendarId: String(event.calendarId || event.calendar_uid || ''),
    calendarName: plainDisplay(event.calendarName || event.calendar || 'Calendar', 120),
    calendarColor: String(event.calendarColor || event.color || ''),
    title: plainDisplay(event.title || event.summary || '(No title)', 400) || '(No title)',
    location: plainDisplay(event.location, 400),
    description: plainDisplay(event.description, 2000),
    start: start,
    end: end,
    allDay: event.allDay === true,
    status: String(event.status || 'confirmed'),
    meetingUrl: meeting.url,
    meetingProvider: meeting.provider,
    provider: String(event.provider || ''),
    source: String(event.source || '')
  }
}

function normalizeEvents(events) {
  if (!Array.isArray(events)) return []
  return events.map(normalizedEvent).filter(function(event) { return event.id && event.start })
}

function compareEvents(a, b) {
  if (!!a.allDay !== !!b.allDay) return a.allDay ? -1 : 1
  var start = String(a.start || '').localeCompare(String(b.start || ''))
  if (start !== 0) return start
  return String(a.title || '').localeCompare(String(b.title || ''))
}

function eventDayKeys(event) {
  if (!event) return []
  if (event.allDay === true) {
    var startKey = eventDateKey(event)
    if (!startKey) return []
    var endKey = /^\d{4}-\d{2}-\d{2}$/.test(String(event.end || '')) ? String(event.end).slice(0, 10) : nextDateKey(startKey)
    if (!endKey || endKey <= startKey) return [startKey]
    var keys = []
    var key = startKey
    var guard = 0
    while (key && key < endKey && guard < 366) {
      keys.push(key)
      key = nextDateKey(key)
      guard += 1
    }
    return keys.length ? keys : [startKey]
  }
  var start = parseDateTime(event.start)
  if (!start) return []
  var end = parseDateTime(event.end) || start
  var first = keyForDate(start)
  var last = keyForDate(end)
  if (end.getTime() <= start.getTime()) return first ? [first] : []
  if (end.getHours() === 0 && end.getMinutes() === 0 && end.getSeconds() === 0 && last !== first) {
    var previous = new Date(end.getTime() - 1)
    last = keyForDate(previous)
  }
  var days = []
  var cursor = first
  var n = 0
  while (cursor && cursor <= last && n < 366) {
    days.push(cursor)
    if (cursor === last) break
    cursor = nextDateKey(cursor)
    n += 1
  }
  return days
}

function eventsByDay(events) {
  var result = {}
  normalizeEvents(events).forEach(function(event) {
    eventDayKeys(event).forEach(function(key) {
      if (!result[key]) result[key] = []
      result[key].push(event)
    })
  })
  Object.keys(result).forEach(function(key) { result[key].sort(compareEvents) })
  return result
}

function eventsForDay(events, key) {
  var grouped = Array.isArray(events) ? eventsByDay(events) : (events || {})
  return grouped[String(key || '')] || []
}

function sameDay(a, b) {
  return keyForDate(a) === keyForDate(b)
}

function startOfWeek(date, weekStart) {
  var copy = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  var offset = (copy.getDay() - normalizedWeekStart(weekStart, 1) + 7) % 7
  copy.setDate(copy.getDate() - offset)
  return copy
}

function daysForView(selectedKey, viewMode, weekStart) {
  var selected = dateFromKey(selectedKey)
  if (viewMode === 'day') return [selected]

  var start = startOfWeek(selected, weekStart)
  var count = viewMode === 'work-week' ? 5 : 7
  var days = []
  for (var i = 0; i < count; i++) {
    var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i)
    if (viewMode === 'work-week' && (day.getDay() === 0 || day.getDay() === 6)) {
      count += 1
      continue
    }
    days.push(day)
  }
  return days
}

function viewRange(selectedKey, viewMode, weekStart) {
  var days = daysForView(selectedKey, viewMode, weekStart)
  var first = days[0]
  var last = days[days.length - 1]
  var start = new Date(first.getFullYear(), first.getMonth(), first.getDate(), 0, 0, 0, 0)
  var end = new Date(last.getFullYear(), last.getMonth(), last.getDate() + 1, 0, 0, 0, 0)
  return { start: start.toISOString(), end: end.toISOString() }
}

function viewTitle(selectedKey, viewMode, weekStart) {
  var days = daysForView(selectedKey, viewMode, weekStart)
  if (viewMode === 'day') return WEEKDAY_NAMES[days[0].getDay()] + ', ' + MONTH_NAMES[days[0].getMonth()] + ' ' + days[0].getDate()
  var first = days[0]
  var last = days[days.length - 1]
  var sameMonth = first.getMonth() === last.getMonth() && first.getFullYear() === last.getFullYear()
  if (sameMonth) return MONTH_NAMES[first.getMonth()] + ' ' + first.getDate() + '-' + last.getDate() + ', ' + first.getFullYear()
  if (first.getFullYear() === last.getFullYear()) return SHORT_MONTH_NAMES[first.getMonth()] + ' ' + first.getDate() + ' - ' + SHORT_MONTH_NAMES[last.getMonth()] + ' ' + last.getDate() + ', ' + first.getFullYear()
  return SHORT_MONTH_NAMES[first.getMonth()] + ' ' + first.getDate() + ', ' + first.getFullYear() + ' - ' + SHORT_MONTH_NAMES[last.getMonth()] + ' ' + last.getDate() + ', ' + last.getFullYear()
}

function eventHour(event, dayKey) {
  var date = parseDateTime(event && event.start)
  if (!date) return 0
  if (dayKey && localDateKeyFromIso(event.start) !== dayKey) return 0
  return date.getHours() + date.getMinutes() / 60
}

function eventEndHour(event, dayKey) {
  var start = parseDateTime(event && event.start)
  var end = parseDateTime(event && event.end)
  if (!start) return 0
  if (!end || end <= start) return eventHour(event, dayKey) + 0.5
  var startKey = localDateKeyFromIso(event.start)
  var endKey = localDateKeyFromIso(event.end)
  if (dayKey && startKey && startKey !== dayKey && (!endKey || endKey !== dayKey)) return 24
  if (dayKey && endKey && endKey !== dayKey) return 24
  return end.getHours() + end.getMinutes() / 60
}

function allDayEventsForDay(events, key) {
  return eventsForDay(events, key).filter(function(event) { return event.allDay === true })
}

function nextDateKey(dayKey) {
  var date = dateFromKey(dayKey, null)
  if (!date) return ''
  date.setDate(date.getDate() + 1)
  return keyForDate(date)
}

function layoutTimedEvents(events, dayKey, hourStart, hourEnd) {
  var segments = eventsForDay(events, dayKey).filter(function(event) { return event.allDay !== true }).map(function(event) {
    var start = Math.max(hourStart, eventHour(event, dayKey))
    var end = Math.min(hourEnd, eventEndHour(event, dayKey))
    if (end <= start) end = Math.min(hourEnd, start + 0.5)
    return { event: event, startHour: start, endHour: end, lane: 0, lanes: 1 }
  }).filter(function(segment) { return segment.endHour > hourStart && segment.startHour < hourEnd })

  segments.sort(function(a, b) {
    if (a.startHour !== b.startHour) return a.startHour - b.startHour
    if (a.endHour !== b.endHour) return b.endHour - a.endHour
    return String(a.event.title || '').localeCompare(String(b.event.title || ''))
  })

  var cluster = []
  var clusterEnd = -1
  function finishCluster() {
    if (cluster.length === 0) return
    var laneEnds = []
    cluster.forEach(function(segment) {
      var lane = 0
      while (lane < laneEnds.length && laneEnds[lane] > segment.startHour) lane += 1
      segment.lane = lane
      laneEnds[lane] = segment.endHour
    })
    var laneCount = Math.max(1, laneEnds.length)
    cluster.forEach(function(segment) { segment.lanes = laneCount })
    cluster = []
    clusterEnd = -1
  }

  segments.forEach(function(segment) {
    if (cluster.length > 0 && segment.startHour >= clusterEnd) finishCluster()
    cluster.push(segment)
    clusterEnd = Math.max(clusterEnd, segment.endHour)
  })
  finishCluster()
  return segments
}

function eventCountForDay(events, key) {
  return eventsForDay(events, key).length
}

function eventDateKey(event) {
  var text = String(event && event.start || '')
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) return text
  return localDateKeyFromIso(text)
}

function eventIsPast(event, now) {
  if (!event) return false
  var current = now && !isNaN(now.getTime()) ? now : new Date()
  if (event.allDay === true) {
    var key = eventDateKey(event)
    return key !== '' && key < keyForDate(current)
  }
  var end = parseDateTime(event.end) || parseDateTime(event.start)
  return !!(end && end.getTime() <= current.getTime())
}

function monthRange(year, month) {
  var start = new Date(year, month, 1, 0, 0, 0, 0)
  var end = new Date(year, month + 1, 1, 0, 0, 0, 0)
  return { start: start.toISOString(), end: end.toISOString() }
}

function dayRange(key) {
  var date = dateFromKey(key, null)
  if (!date) return null
  var start = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0)
  var end = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1, 0, 0, 0, 0)
  return { start: start.toISOString(), end: end.toISOString() }
}

function daysInMonth(year, month) {
  return new Date(year, month + 1, 0).getDate()
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var days = []
  for (var i = 0; i < 7; i++) days.push((start + i) % 7)
  return days
}

function normalizedWeekStart(value, fallback) {
  if (value === null || value === undefined || value === '') return fallback === undefined ? 1 : fallback
  var numeric = Number(value)
  if (!isNaN(numeric) && numeric >= 0 && numeric <= 6) return Math.floor(numeric)
  var named = String(value).toLowerCase().slice(0, 3)
  var names = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }
  return names[named] === undefined ? (fallback === undefined ? 1 : fallback) : names[named]
}

function isoWeek(year, month, day) {
  var date = new Date(Date.UTC(year, month, day))
  date.setUTCDate(date.getUTCDate() + 4 - (date.getUTCDay() || 7))
  var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil((((date - yearStart) / 86400000) + 1) / 7)
}

function monthGrid(year, month, weekStart, todayKey, groupedEvents) {
  var first = new Date(year, month, 1)
  var offset = (first.getDay() - normalizedWeekStart(weekStart, 1) + 7) % 7
  var cursor = new Date(year, month, 1 - offset)
  var weeks = []
  for (var row = 0; row < 6; row++) {
    var days = []
    for (var col = 0; col < 7; col++) {
      var key = keyForDate(cursor)
      var dayEvents = eventsForDay(groupedEvents || {}, key)
      days.push({
        key: key,
        year: cursor.getFullYear(),
        month: cursor.getMonth(),
        day: cursor.getDate(),
        weekday: cursor.getDay(),
        inMonth: cursor.getMonth() === month,
        weekend: cursor.getDay() === 0 || cursor.getDay() === 6,
        today: key === todayKey,
        eventCount: dayEvents.length,
        previews: dayEvents.slice(0, 2),
        extra: Math.max(0, dayEvents.length - 2)
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    weeks.push({ week: isoWeek(days[3].year, days[3].month, days[3].day), days: days })
  }
  return weeks
}

function stepMonth(year, month, delta) {
  var date = new Date(year, month + delta, 1)
  return { year: date.getFullYear(), month: date.getMonth() }
}

function clockFormats(vertical) {
  return vertical
    ? ['HH\n—\nmm', 'h\n—\nmm\nAP', "dd\nMMM\n'W'ww\n''yy", 'HH\nmm']
    : ['dddd HH:mm', 'dddd h:mm AP', 'HH:mm', 'h:mm AP', 'ddd d MMM HH:mm', "d MMMM 'W'ww yyyy", 'yyyy-MM-dd HH:mm']
}

function clockFormatRing(format, altFormat, presets) {
  var ring = (presets || []).slice()
  ;[format, altFormat].forEach(function(value) {
    if (value && ring.indexOf(value) === -1) ring.push(value)
  })
  return ring.length ? ring : ['HH:mm']
}

function nextClockFormat(ring, current) {
  var list = ring && ring.length ? ring : ['HH:mm']
  var index = list.indexOf(current)
  return list[(index + 1) % list.length]
}

function formatTime(iso, allDay, format) {
  if (allDay) return 'All day'
  var date = parseDateTime(iso)
  if (!date) return ''
  return formatClockTime(date.getHours(), date.getMinutes(), format)
}

function formatClockTime(hour, minute, format) {
  if (hour === 24) return format === '24h' ? '24:00' : '12 AM next day'
  if (format === '24h') return pad2(hour) + ':' + pad2(minute)
  var suffix = hour >= 12 ? 'PM' : 'AM'
  var displayHour = hour % 12
  if (displayHour === 0) displayHour = 12
  return minute === 0 ? displayHour + ' ' + suffix : displayHour + ':' + pad2(minute) + ' ' + suffix
}

function formatHourLabel(hour, format) {
  if (hour === 24) return format === '24h' ? '00:00' : '12 AM'
  return formatClockTime(((hour % 24) + 24) % 24, 0, format)
}

function parseTimeText(value) {
  var text = String(value || '').trim().toLowerCase().replace(/\s+/g, '')
  var match = text.match(/^(\d{1,2})(?::(\d{2}))?([ap]m?)?$/)
  if (!match) return null
  var hour = parseInt(match[1], 10)
  var minute = match[2] === undefined ? 0 : parseInt(match[2], 10)
  var suffix = match[3] || ''
  if (minute < 0 || minute > 59) return null
  if (suffix) {
    if (hour < 1 || hour > 12) return null
    if (suffix[0] === 'a') hour = hour === 12 ? 0 : hour
    else hour = hour === 12 ? 12 : hour + 12
  } else if (hour < 0 || hour > 24 || (hour === 24 && minute !== 0)) {
    return null
  }
  return { hour: hour, minute: minute }
}

function parseInstantMs(value) {
  var text = String(value || '')
  if (!text) return NaN
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) return Date.parse(text + 'T00:00:00Z')
  return Date.parse(text)
}

function eventsInRange(events, startIso, endIso) {
  var start = Date.parse(String(startIso || ''))
  var end = Date.parse(String(endIso || ''))
  var list = normalizeEvents(events)
  if (isNaN(start) || isNaN(end)) return list
  return list.filter(function(event) {
    var eventStart = parseInstantMs(event.start)
    var eventEnd = parseInstantMs(event.end)
    if (isNaN(eventStart)) return false
    if (isNaN(eventEnd)) eventEnd = eventStart
    return eventStart < end && eventEnd >= start
  })
}

function parseHelperResponse(text) {
  try {
    var parsed = JSON.parse(String(text || '{}'))
    return {
      ok: parsed.ok === true,
      provider: String(parsed.provider || ''),
      calendars: Array.isArray(parsed.calendars) ? parsed.calendars : [],
      events: normalizeEvents(parsed.events),
      error: parsed.error || null
    }
  } catch (error) {
    return { ok: false, provider: '', calendars: [], events: [], error: { code: 'invalid-json', message: String(error) } }
  }
}

function parseOperationResponse(text) {
  try {
    var parsed = JSON.parse(String(text || '{}'))
    return {
      ok: parsed.ok === true,
      provider: String(parsed.provider || ''),
      calendar: parsed.calendar || null,
      event: parsed.event ? normalizedEvent(parsed.event) : null,
      uid: String(parsed.uid || (parsed.event && parsed.event.uid) || ''),
      signedIn: parsed.signedIn === true,
      account: String(parsed.account || ''),
      error: parsed.error || null
    }
  } catch (error) {
    return { ok: false, provider: '', calendar: null, event: null, uid: '', error: { code: 'invalid-json', message: String(error) } }
  }
}

var DEFAULT_CALENDAR_COLORS = ['#8aadf4', '#a6e3a1', '#f9e2af', '#f38ba8', '#cba6f7', '#94e2d5', '#fab387', '#89dceb', '#f2cdcd', '#b4befe']

function copyMap(value) {
  var result = {}
  if (!value || typeof value !== 'object' || Array.isArray(value)) return result
  Object.keys(value).forEach(function(key) { result[key] = value[key] })
  return result
}

function providerLabel(provider, host) {
  var hostname = String(host || '').toLowerCase().replace(/^www\./, '')
  if (hostname) {
    var labels = hostname.split('.')
    if (labels[0] === 'caldav' || labels[0] === 'carddav' || labels[0] === 'dav') labels = labels.slice(1)
    var domain = labels.slice(-2).join('.')
    var named = {
      'icloud.com': 'iCloud',
      'icloud.com.cn': 'iCloud',
      'google.com': 'Google',
      'googleapis.com': 'Google',
      'fastmail.com': 'Fastmail',
      'fastmail.fm': 'Fastmail',
      'yahoo.com': 'Yahoo'
    }
    if (named[domain]) return named[domain]
    if (named[hostname]) return named[hostname]
    var label = labels[0] || hostname
    return label.charAt(0).toUpperCase() + label.slice(1)
  }
  if (provider === 'caldav') return 'CalDAV'
  if (provider === 'local') return 'On this computer'
  if (provider === 'gnome-online-accounts') return 'Online account'
  return 'Local'
}

function calendarDisplayName(calendar, names) {
  if (!calendar) return 'Calendar'
  var overrides = names || {}
  var override = overrides[calendar.id]
  if (override) return String(override)
  return plainDisplay(calendar.name || 'Calendar', 120) || 'Calendar'
}

function calendarDisplayColor(calendar, colors, index) {
  if (!calendar) return DEFAULT_CALENDAR_COLORS[0]
  var overrides = colors || {}
  if (overrides[calendar.id]) return String(overrides[calendar.id])
  if (calendar.color) return String(calendar.color)
  return DEFAULT_CALENDAR_COLORS[Math.abs(index || 0) % DEFAULT_CALENDAR_COLORS.length]
}

function calendarChoiceLabel(calendar, names) {
  if (!calendar) return 'Calendar'
  return calendarDisplayName(calendar, names) + ' · ' + providerLabel(calendar.provider, calendar.host)
}

function normalizeColor(color) {
  var value = String(color || '').replace('#', '').toLowerCase()
  if (value.length === 8) value = value.slice(0, 6)
  if (value.length === 3) value = value.split('').map(function(part) { return part + part }).join('')
  return value ? '#' + value : ''
}

function colorsMatch(a, b) {
  var left = normalizeColor(a)
  var right = normalizeColor(b)
  return left !== '' && left === right
}

function colorLuminance(color) {
  var hex = normalizeColor(color).slice(1)
  if (hex.length < 6) return 0
  var r = parseInt(hex.slice(0, 2), 16) / 255
  var g = parseInt(hex.slice(2, 4), 16) / 255
  var b = parseInt(hex.slice(4, 6), 16) / 255
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrastingForeground(color, fillStrength, lightText, darkText) {
  var strength = fillStrength === undefined ? 1 : fillStrength
  var perceived = colorLuminance(color) * strength
  return perceived > 0.32 ? (darkText || '#1e1e2e') : (lightText || '#cdd6f4')
}

function canRemoveCalendar(calendar) {
  return !!(calendar && calendar.id)
}

function dateTimeIso(dayKey, timeText) {
  var time = parseTimeText(timeText)
  if (!time) return ''
  var hour = time.hour
  var minute = time.minute
  var date = dateFromKey(dayKey, null)
  if (!date) return ''
  if (hour === 24) {
    date.setDate(date.getDate() + 1)
    hour = 0
  }
  date.setHours(hour, minute, 0, 0)
  return date.toISOString()
}

function endDateTimeIso(dayKey, startTime, endTime) {
  var startIso = dateTimeIso(dayKey, startTime)
  var sameDayEnd = dateTimeIso(dayKey, endTime)
  if (!startIso || !sameDayEnd) return ''
  if (Date.parse(sameDayEnd) > Date.parse(startIso)) return sameDayEnd
  if (String(startTime) === String(endTime)) return ''
  return dateTimeIso(nextDateKey(dayKey), endTime)
}

function eventListTime(event, dayKey, format) {
  if (!event) return ''
  if (event.allDay === true) return 'All day'
  if (dayKey && localDateKeyFromIso(event.start) !== dayKey) return formatClockTime(0, 0, format)
  return formatTime(event.start, false, format)
}

var ICAL_WEEKDAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA']

function icalWeekday(jsDay) {
  return ICAL_WEEKDAYS[(((jsDay || 0) % 7) + 7) % 7]
}

function jsWeekday(token) {
  var index = ICAL_WEEKDAYS.indexOf(String(token || '').toUpperCase())
  return index < 0 ? 1 : index
}

function weekdayOccurrence(date) {
  var nth = Math.ceil(date.getDate() / 7)
  var next = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 7)
  return { nth: nth, last: next.getMonth() !== date.getMonth() }
}

function ordinalLabel(value) {
  var n = Number(value)
  if (n === -1) return 'last'
  var names = { 1: 'first', 2: 'second', 3: 'third', 4: 'fourth', 5: 'fifth' }
  return names[n] || String(value)
}

function joinList(items) {
  var list = (items || []).filter(function(item) { return item })
  if (list.length <= 1) return list[0] || ''
  if (list.length === 2) return list[0] + ' and ' + list[1]
  return list.slice(0, -1).join(', ') + ', and ' + list[list.length - 1]
}

function formatDateKey(key) {
  var date = dateFromKey(key, null)
  if (!date) return String(key || '')
  return SHORT_MONTH_NAMES[date.getMonth()] + ' ' + date.getDate() + ', ' + date.getFullYear()
}

function normalizedWeekdays(value, fallbackDay) {
  var days = [false, false, false, false, false, false, false]
  if (Array.isArray(value)) {
    for (var i = 0; i < 7; i++) days[i] = value[i] === true
  }
  if (!days.some(Boolean) && fallbackDay !== undefined && fallbackDay !== null && fallbackDay !== '') {
    days[(((fallbackDay % 7) + 7) % 7)] = true
  }
  return days
}

function isWeekdayPattern(days) {
  return !!(days && days[1] && days[2] && days[3] && days[4] && days[5] && !days[0] && !days[6])
}

function copyRecurrence(rec) {
  rec = rec || {}
  return {
    freq: String(rec.freq || 'never'),
    interval: Math.max(1, Math.min(99, parseInt(rec.interval, 10) || 1)),
    weekdays: normalizedWeekdays(rec.weekdays, rec.weekday),
    weekdaysOnly: rec.weekdaysOnly === true || rec.freq === 'weekday',
    monthlyMode: rec.monthlyMode === 'byday' ? 'byday' : 'bymonthday',
    yearlyMode: rec.yearlyMode === 'byday' ? 'byday' : 'bymonthday',
    monthDay: Math.max(1, Math.min(31, parseInt(rec.monthDay, 10) || 1)),
    month: Math.max(1, Math.min(12, parseInt(rec.month, 10) || 1)),
    bysetpos: parseInt(rec.bysetpos, 10) || 1,
    weekday: (((parseInt(rec.weekday, 10) || 0) % 7) + 7) % 7,
    end: rec.end === 'until' || rec.end === 'count' ? rec.end : 'never',
    until: String(rec.until || ''),
    count: Math.max(1, Math.min(730, parseInt(rec.count, 10) || 10))
  }
}

function defaultRecurrence(dayKey) {
  var date = dateFromKey(dayKey, new Date())
  var occ = weekdayOccurrence(date)
  var until = new Date(date.getFullYear(), date.getMonth() + 3, date.getDate())
  return copyRecurrence({
    freq: 'never',
    interval: 1,
    weekdays: normalizedWeekdays(null, date.getDay()),
    monthlyMode: 'bymonthday',
    yearlyMode: 'bymonthday',
    monthDay: date.getDate(),
    month: date.getMonth() + 1,
    bysetpos: occ.last ? -1 : occ.nth,
    weekday: date.getDay(),
    end: 'never',
    until: keyForDate(until),
    count: 10
  })
}

function recurrenceForDate(rec, dayKey) {
  var next = copyRecurrence(rec)
  var date = dateFromKey(dayKey, new Date())
  var occ = weekdayOccurrence(date)
  var selected = next.weekdays.filter(Boolean).length
  next.monthDay = date.getDate()
  next.month = date.getMonth() + 1
  next.weekday = date.getDay()
  next.bysetpos = next.monthlyMode === 'byday' || next.yearlyMode === 'byday'
    ? (occ.last && next.bysetpos === -1 ? -1 : occ.nth)
    : (occ.last ? -1 : occ.nth)
  if (selected <= 1) next.weekdays = normalizedWeekdays(null, date.getDay())
  if (!next.until) next.until = keyForDate(new Date(date.getFullYear(), date.getMonth() + 3, date.getDate()))
  return next
}

function monthlyOccurrenceOptions(dayKey) {
  var date = dateFromKey(dayKey, new Date())
  var occ = weekdayOccurrence(date)
  var weekday = WEEKDAY_NAMES[date.getDay()]
  var options = [{ value: 'bymonthday', label: 'On day ' + date.getDate() }]
  options.push({ value: 'byday:' + occ.nth, label: 'On the ' + ordinalLabel(occ.nth) + ' ' + weekday })
  if (occ.last) options.push({ value: 'byday:-1', label: 'On the last ' + weekday })
  return options
}

function monthDayOptions() {
  var options = []
  for (var day = 1; day <= 31; day++) options.push({ value: String(day), label: String(day) })
  return options
}

function weekdayNameOptions() {
  return WEEKDAY_NAMES.map(function(name, index) { return { value: String(index), label: name } })
}

function ordinalOptions() {
  return [
    { value: '1', label: 'first' },
    { value: '2', label: 'second' },
    { value: '3', label: 'third' },
    { value: '4', label: 'fourth' },
    { value: '5', label: 'fifth' },
    { value: '-1', label: 'last' }
  ]
}

function monthNameOptions() {
  return MONTH_NAMES.map(function(name, index) { return { value: String(index + 1), label: name } })
}

function yearlyOccurrenceOptions(dayKey) {
  var date = dateFromKey(dayKey, new Date())
  var occ = weekdayOccurrence(date)
  var weekday = WEEKDAY_NAMES[date.getDay()]
  var month = MONTH_NAMES[date.getMonth()]
  var options = [{ value: 'bymonthday', label: 'On ' + month + ' ' + date.getDate() }]
  options.push({ value: 'byday:' + occ.nth, label: 'On the ' + ordinalLabel(occ.nth) + ' ' + weekday + ' of ' + month })
  if (occ.last) options.push({ value: 'byday:-1', label: 'On the last ' + weekday + ' of ' + month })
  return options
}

function nextOccurrenceDate(dayKey, rec) {
  var date = dateFromKey(dayKey, new Date())
  var rule = copyRecurrence(rec)
  if (!rule.freq || rule.freq === 'never') return keyForDate(date)
  if (rule.freq === 'weekly' || rule.freq === 'weekday' || rule.weekdaysOnly) {
    var days = (rule.freq === 'weekday' || rule.weekdaysOnly) ? [false, true, true, true, true, true, false] : rule.weekdays
    if (!days.some(Boolean)) return keyForDate(date)
    for (var i = 0; i < 7; i++) {
      if (days[date.getDay()]) return keyForDate(date)
      date.setDate(date.getDate() + 1)
    }
  }
  return keyForDate(date)
}

function matchesRecurrenceDate(rec, date, seriesStart) {
  var rule = copyRecurrence(rec)
  var startDay = new Date(seriesStart.getFullYear(), seriesStart.getMonth(), seriesStart.getDate())
  var day = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  if (day < startDay) return false
  var dayMs = 86400000
  if (rule.freq === 'daily') {
    return Math.round((day - startDay) / dayMs) % rule.interval === 0
  }
  if (rule.freq === 'weekly' || rule.freq === 'weekday' || rule.weekdaysOnly) {
    var days = (rule.freq === 'weekday' || rule.weekdaysOnly) ? [false, true, true, true, true, true, false] : rule.weekdays
    if (!days[day.getDay()]) return false
    var startWeek = startOfWeek(startDay, 0)
    var thisWeek = startOfWeek(day, 0)
    return Math.round((thisWeek - startWeek) / (7 * dayMs)) % rule.interval === 0
  }
  if (rule.freq === 'monthly') {
    if ((day.getMonth() - startDay.getMonth() + 12 * (day.getFullYear() - startDay.getFullYear())) % rule.interval !== 0) return false
    if (rule.monthlyMode === 'byday') {
      if (day.getDay() !== rule.weekday) return false
      var monthOcc = weekdayOccurrence(day)
      return rule.bysetpos === -1 ? monthOcc.last : monthOcc.nth === rule.bysetpos
    }
    return day.getDate() === rule.monthDay
  }
  if (rule.freq === 'yearly') {
    if ((day.getFullYear() - startDay.getFullYear()) % rule.interval !== 0) return false
    if (day.getMonth() + 1 !== rule.month) return false
    if (rule.yearlyMode === 'byday') {
      if (day.getDay() !== rule.weekday) return false
      var yearOcc = weekdayOccurrence(day)
      return rule.bysetpos === -1 ? yearOcc.last : yearOcc.nth === rule.bysetpos
    }
    return day.getDate() === rule.monthDay
  }
  return false
}

function expandRecurringEvent(baseEvent, rrule, rangeStart, rangeEnd) {
  var rec = parseRRule(rrule, baseEvent && baseEvent.allDay ? eventDateKey(baseEvent) : localDateKeyFromIso(baseEvent && baseEvent.start))
  if (!baseEvent || !baseEvent.start || !rec.freq || rec.freq === 'never') return baseEvent ? [baseEvent] : []
  var start = baseEvent.allDay ? dateFromKey(eventDateKey(baseEvent), null) : parseDateTime(baseEvent.start)
  var end = baseEvent.allDay ? dateFromKey(String(baseEvent.end || '').slice(0, 10) || nextDateKey(eventDateKey(baseEvent)), null) : (parseDateTime(baseEvent.end) || start)
  if (!start) return [baseEvent]
  var duration = Math.max(0, (end && end.getTime ? end.getTime() : start.getTime()) - start.getTime())
  var windowStart = parseDateTime(rangeStart) || start
  var windowEnd = parseDateTime(rangeEnd) || new Date(start.getTime() + 40 * 86400000)
  var until = rec.end === 'until' && rec.until ? dateFromKey(rec.until, null) : null
  var limit = rec.end === 'count' ? rec.count : 80
  var results = []
  var cursor = new Date(start.getFullYear(), start.getMonth(), start.getDate())
  var guard = 0
  while (results.length < limit && guard < 500) {
    guard += 1
    if (until && cursor > until) break
    var occStart = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate(), start.getHours(), start.getMinutes(), 0, 0)
    if (occStart >= windowEnd) break
    if (matchesRecurrenceDate(rec, cursor, start) && occStart >= new Date(start.getFullYear(), start.getMonth(), start.getDate(), start.getHours(), start.getMinutes(), 0, 0)) {
      var occEnd = new Date(occStart.getTime() + duration)
      if (occEnd > windowStart) {
        var event = {}
        Object.keys(baseEvent).forEach(function(key) { event[key] = baseEvent[key] })
        event.start = baseEvent.allDay ? keyForDate(occStart) : occStart.toISOString()
        event.end = baseEvent.allDay ? nextDateKey(keyForDate(occStart)) : occEnd.toISOString()
        event.recurring = true
        event.rid = event.start
        event.id = String(baseEvent.id || baseEvent.uid || 'event') + ':' + keyForDate(occStart)
        results.push(event)
      }
    }
    cursor.setDate(cursor.getDate() + 1)
  }
  return results.length ? results : [baseEvent]
}

function serializeRecurrence(rec) {
  var rule = copyRecurrence(rec)
  var freq = rule.freq
  if (!freq || freq === 'never') return ''
  if (freq === 'weekday' || rule.weekdaysOnly) {
    freq = 'weekly'
    rule.weekdays = [false, true, true, true, true, true, false]
  }
  if (['daily', 'weekly', 'monthly', 'yearly'].indexOf(freq) < 0) return ''
  var parts = ['FREQ=' + freq.toUpperCase()]
  if (rule.interval > 1) parts.push('INTERVAL=' + rule.interval)
  if (freq === 'weekly') {
    var days = []
    for (var i = 0; i < 7; i++) if (rule.weekdays[i]) days.push(ICAL_WEEKDAYS[i])
    if (!days.length) days.push(icalWeekday(rule.weekday))
    parts.push('BYDAY=' + days.join(','))
  }
  if (freq === 'monthly') {
    if (rule.monthlyMode === 'byday') {
      parts.push('BYDAY=' + icalWeekday(rule.weekday))
      parts.push('BYSETPOS=' + rule.bysetpos)
    } else {
      parts.push('BYMONTHDAY=' + rule.monthDay)
    }
  }
  if (freq === 'yearly') {
    parts.push('BYMONTH=' + rule.month)
    if (rule.yearlyMode === 'byday') {
      parts.push('BYDAY=' + icalWeekday(rule.weekday))
      parts.push('BYSETPOS=' + rule.bysetpos)
    } else {
      parts.push('BYMONTHDAY=' + rule.monthDay)
    }
  }
  if (rule.end === 'count') parts.push('COUNT=' + rule.count)
  if (rule.end === 'until' && /^\d{4}-\d{2}-\d{2}$/.test(rule.until)) {
    parts.push('UNTIL=' + rule.until.replace(/-/g, '') + 'T235959Z')
  }
  return parts.join(';')
}

function parseRRule(rrule, dayKey) {
  var rec = defaultRecurrence(dayKey)
  var text = String(rrule || '').trim()
  if (text.toUpperCase().indexOf('RRULE:') === 0) text = text.slice(6).trim()
  if (!text || ['never', 'none', ''].indexOf(text.toLowerCase()) >= 0) return rec
  var parts = {}
  text.split(';').forEach(function(part) {
    var index = part.indexOf('=')
    if (index > 0) parts[part.slice(0, index).toUpperCase()] = part.slice(index + 1)
  })
  var freq = String(parts.FREQ || '').toLowerCase()
  if (!freq) return rec
  rec.freq = freq
  rec.interval = Math.max(1, parseInt(parts.INTERVAL, 10) || 1)
  if (parts.COUNT) {
    rec.end = 'count'
    rec.count = Math.max(1, parseInt(parts.COUNT, 10) || 10)
  }
  if (parts.UNTIL) {
    rec.end = 'until'
    var until = String(parts.UNTIL).replace(/-/g, '').slice(0, 8)
    if (/^\d{8}$/.test(until)) rec.until = [until.slice(0, 4), until.slice(4, 6), until.slice(6, 8)].join('-')
  }
  if (parts.BYMONTHDAY) rec.monthDay = Math.max(1, Math.min(31, parseInt(parts.BYMONTHDAY, 10) || rec.monthDay))
  if (parts.BYMONTH) rec.month = Math.max(1, Math.min(12, parseInt(parts.BYMONTH, 10) || rec.month))
  if (parts.BYSETPOS) rec.bysetpos = parseInt(parts.BYSETPOS, 10) || rec.bysetpos
  if (parts.BYDAY) {
    var days = [false, false, false, false, false, false, false]
    String(parts.BYDAY).split(',').forEach(function(token) {
      var match = String(token).trim().match(/^(-?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/i)
      if (!match) return
      if (match[1]) rec.bysetpos = parseInt(match[1], 10)
      rec.weekday = jsWeekday(match[2])
      days[rec.weekday] = true
    })
    rec.weekdays = days
  }
  if (freq === 'monthly' && (parts.BYDAY || parts.BYSETPOS)) rec.monthlyMode = 'byday'
  if (freq === 'yearly' && (parts.BYDAY || parts.BYSETPOS)) rec.yearlyMode = 'byday'
  if (freq === 'weekly' && isWeekdayPattern(rec.weekdays)) {
    rec.freq = 'weekday'
    rec.weekdaysOnly = true
  }
  return rec
}

function summarizeRecurrence(rec, startKey) {
  var rule = copyRecurrence(rec)
  if (!rule.freq || rule.freq === 'never') return 'Does not repeat'
  var interval = rule.interval
  var text = ''
  if (rule.freq === 'weekday' || rule.weekdaysOnly) {
    text = interval === 1 ? 'Every weekday' : ('Every ' + interval + ' weeks on weekdays')
  } else if (rule.freq === 'daily') {
    text = interval === 1 ? 'Every day' : ('Every ' + interval + ' days')
  } else if (rule.freq === 'weekly') {
    var names = []
    for (var i = 0; i < 7; i++) if (rule.weekdays[i]) names.push(WEEKDAY_NAMES[i])
    text = interval === 1 ? 'Every week' : ('Every ' + interval + ' weeks')
    if (names.length) text += ' on ' + joinList(names)
  } else if (rule.freq === 'monthly') {
    text = interval === 1 ? 'Every month' : ('Every ' + interval + ' months')
    if (rule.monthlyMode === 'byday') text += ' on the ' + ordinalLabel(rule.bysetpos) + ' ' + WEEKDAY_NAMES[rule.weekday]
    else text += ' on day ' + rule.monthDay
  } else if (rule.freq === 'yearly') {
    text = interval === 1 ? 'Every year' : ('Every ' + interval + ' years')
    if (rule.yearlyMode === 'byday') text += ' on the ' + ordinalLabel(rule.bysetpos) + ' ' + WEEKDAY_NAMES[rule.weekday] + ' of ' + MONTH_NAMES[rule.month - 1]
    else text += ' on ' + MONTH_NAMES[rule.month - 1] + ' ' + rule.monthDay
  } else {
    return 'Does not repeat'
  }
  if (rule.end === 'count') text += ', ' + rule.count + ' time' + (rule.count === 1 ? '' : 's')
  if (rule.end === 'until' && rule.until) text += ', until ' + formatDateKey(rule.until)
  if (startKey) text += ', starting ' + formatDateKey(startKey)
  return text
}

if (typeof module !== 'undefined') module.exports = {
  calendarChoiceLabel,
  calendarDisplayColor,
  calendarDisplayName,
  canRemoveCalendar,
  colorLuminance,
  colorsMatch,
  contrastingForeground,
  clockFormatRing,
  clockFormats,
  copyMap,
  DEFAULT_CALENDAR_COLORS,
  allDayEventsForDay,
  compareEvents,
  dateKey,
  copyRecurrence,
  dateTimeIso,
  dateFromKey,
  endDateTimeIso,
  dueReminders,
  defaultRecurrence,
  daysForView,
  dayRange,
  eventHour,
  eventEndHour,
  eventMeeting,
  eventCountForDay,
  eventDateKey,
  eventDayKeys,
  eventIsPast,
  eventListTime,
  eventsByDay,
  eventsForDay,
  expandRecurringEvent,
  eventsInRange,
  formatClockTime,
  formatDateKey,
  formatHourLabel,
  formatTime,
  keyForDate,
  localDateKeyFromIso,
  layoutTimedEvents,
  monthDayOptions,
  meetingFromText,
  normalizeMeetingUrl,
  meetingProviderLabel,
  monthGrid,
  monthNameOptions,
  monthRange,
  monthlyOccurrenceOptions,
  nextClockFormat,
  nextDateKey,
  nextOccurrenceDate,
  normalizedReminderMinutes,
  normalizedWeekdays,
  normalizeEvents,
  ordinalOptions,
  normalizedEvent,
  normalizedWeekStart,
  parseHelperResponse,
  parseOperationResponse,
  plainDisplay,
  parseRRule,
  parseTimeText,
  pruneFiredKeys,
  providerLabel,
  reminderBody,
  reminderDue,
  reminderKey,
  recurrenceForDate,
  sameDay,
  serializeRecurrence,
  stepMonth,
  summarizeRecurrence,
  viewRange,
  viewTitle,
  weekdayNameOptions,
  weekdayOccurrence,
  weekdayOrder,
  yearlyOccurrenceOptions
}
