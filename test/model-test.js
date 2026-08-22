const assert = require('assert')
const model = require('../CalendarModel.js')

const events = model.normalizeEvents([
  {
    uid: '2',
    calendar_uid: 'work',
    calendar: 'Work',
    summary: 'Later',
    start: '2026-08-20T17:00:00Z',
    end: '2026-08-20T18:00:00Z'
  },
  {
    id: '1',
    calendarId: 'personal',
    calendarName: 'Personal',
    title: 'Earlier',
    start: '2026-08-20T09:00:00Z',
    end: '2026-08-20T10:00:00Z'
  }
])

assert.equal(events.length, 2)
assert.equal(events[0].id, '2')
assert.equal(events[0].uid, '2')
assert.equal(events[0].calendarId, 'work')
assert.equal(events[0].title, 'Later')
assert.equal(model.plainDisplay('<img src="https://evil.test/x">Alert'), 'Alert')
assert.equal(model.normalizeEvents([{ id: 'x', title: '<b>Hi</b>', start: '2026-08-20T09:00:00Z' }])[0].title, 'Hi')

const grouped = model.eventsByDay(events)
assert.equal(grouped['2026-08-20'].length, 2)
assert.equal(grouped['2026-08-20'][0].title, 'Earlier')
assert.equal(model.eventCountForDay(grouped, '2026-08-20'), 2)
assert.equal(model.eventCountForDay(grouped, '2026-08-21'), 0)

const grid = model.monthGrid(2026, 7, 1, '2026-08-20', grouped)
assert.equal(grid.length, 6)
assert(grid.every(week => week.days.length === 7))
const selected = grid.flatMap(week => week.days).find(day => day.key === '2026-08-20')
assert.equal(selected.today, true)
assert.equal(selected.eventCount, 2)
assert.equal(selected.previews.length, 2)
assert.equal(selected.extra, 0)
assert.equal(selected.previews[0].title, 'Earlier')

assert.equal(model.eventIsPast({ start: '2026-08-21T09:00:00Z', end: '2026-08-21T10:00:00Z', allDay: false }, new Date('2026-08-21T15:00:00Z')), true)
assert.equal(model.eventIsPast({ start: '2026-08-21T14:00:00Z', end: '2026-08-21T16:00:00Z', allDay: false }, new Date('2026-08-21T15:00:00Z')), false)
assert.equal(model.eventIsPast({ start: '2026-08-21', end: '2026-08-22', allDay: true }, new Date('2026-08-21T15:00:00Z')), false)
assert.equal(model.eventIsPast({ start: '2026-08-20', allDay: true }, new Date('2026-08-21T15:00:00Z')), true)

const overflow = model.monthGrid(2026, 7, 1, '2026-08-20', model.eventsByDay([
  { id: 'a', title: 'A', start: '2026-08-20T09:00:00Z', end: '2026-08-20T10:00:00Z' },
  { id: 'b', title: 'B', start: '2026-08-20T10:00:00Z', end: '2026-08-20T11:00:00Z' },
  { id: 'c', title: 'C', start: '2026-08-20T11:00:00Z', end: '2026-08-20T12:00:00Z' }
])).flatMap(week => week.days).find(day => day.key === '2026-08-20')
assert.equal(overflow.previews.length, 2)
assert.equal(overflow.extra, 1)

const response = model.parseHelperResponse(JSON.stringify({ ok: true, provider: 'mock', calendars: [], events }))
assert.equal(response.ok, true)
assert.equal(response.provider, 'mock')
assert.equal(response.events.length, 2)

const operation = model.parseOperationResponse(JSON.stringify({ ok: true, provider: 'evolution-data-server', uid: 'abc', event: { id: 'abc', title: 'Created', start: '2026-08-20T09:00:00Z' } }))
assert.equal(operation.ok, true)
assert.equal(operation.uid, 'abc')
assert.equal(operation.event.title, 'Created')

const bad = model.parseHelperResponse('{')
assert.equal(bad.ok, false)
assert.equal(bad.error.code, 'invalid-json')

assert.deepEqual(model.weekdayOrder(1), [1, 2, 3, 4, 5, 6, 0])
assert.deepEqual(model.stepMonth(2026, 11, 1), { year: 2027, month: 0 })
assert.match(model.formatTime('2026-08-20T09:05:00Z', false), /AM|PM/)
assert.equal(model.formatTime('2026-08-20T09:05:00Z', true), 'All day')
assert.equal(model.formatClockTime(0, 0), '12 AM')
assert.equal(model.providerLabel('caldav'), 'CalDAV')
assert.equal(model.providerLabel('caldav', 'caldav.icloud.com'), 'iCloud')
assert.equal(model.providerLabel('caldav', 'caldav.fastmail.com'), 'Fastmail')
assert.equal(model.calendarChoiceLabel({ id: 'a', name: 'Personal', provider: 'local' }, {}), 'Personal · On this computer')
assert.equal(model.calendarChoiceLabel({ id: 'b', name: 'Personal', provider: 'caldav', host: 'caldav.icloud.com' }, {}), 'Personal · iCloud')
assert.equal(model.canRemoveCalendar({ id: 'omarchy-calendar-caldav-1', provider: 'caldav' }), true)
assert.equal(model.canRemoveCalendar({ id: 'system-calendar', provider: 'local' }), true)
assert.equal(model.canRemoveCalendar({ id: 'birthdays', provider: 'local', readonly: true }), true)
assert.equal(model.canRemoveCalendar({ id: '', provider: 'local' }), false)
assert.equal(model.colorsMatch('#285FF4FF', '#285ff4'), true)
assert.ok(model.colorLuminance('#f9e2af') > model.colorLuminance('#1e1e2e'))
assert.equal(model.contrastingForeground('#fab387', 0.68, 'light', 'dark'), 'dark')
assert.equal(model.contrastingForeground('#1e1e2e', 0.68, 'light', 'dark'), 'light')
assert.equal(model.calendarDisplayName({ id: 'a', name: 'Personal' }, { a: 'Home' }), 'Home')
assert.equal(model.calendarDisplayColor({ id: 'a', color: '#fff' }, { a: '#8aadf4' }, 0), '#8aadf4')
assert.equal(model.eventsInRange(events, '2026-08-20T00:00:00Z', '2026-08-21T00:00:00Z').length, 2)
assert.equal(model.eventsInRange(events, '2026-08-21T00:00:00Z', '2026-08-22T00:00:00Z').length, 0)
assert.equal(model.formatClockTime(24, 0), '12 AM next day')
assert.equal(model.formatClockTime(24, 0, '24h'), '24:00')
assert.equal(model.formatClockTime(15, 30), '3:30 PM')
assert.equal(model.formatClockTime(15, 30, '24h'), '15:30')
assert.equal(model.formatHourLabel(12), '12 PM')
assert.equal(model.formatHourLabel(24), '12 AM')
assert.equal(model.formatHourLabel(24, '24h'), '00:00')
assert(model.dateTimeIso('2026-08-20', '09:05').endsWith('Z'))
assert.equal(new Date(model.dateTimeIso('2026-08-20', '8am')).getHours(), 8)
assert.equal(new Date(model.dateTimeIso('2026-08-20', '3pm')).getHours(), 15)
assert.equal(new Date(model.dateTimeIso('2026-08-20', '8:30 pm')).getMinutes(), 30)
assert.equal(new Date(model.dateTimeIso('2026-08-20', '24:00')).getUTCDate(), 21)
assert.equal(model.dateTimeIso('bad', '09:05'), '')
assert.equal(model.dateTimeIso('2026-99-99', '09:05'), '')
assert.equal(model.dateTimeIso('2026-08-20', 'bad'), '')
assert.equal(model.dateTimeIso('2026-08-20', '24:30'), '')
assert.equal(model.dateTimeIso('2026-08-20', '13pm'), '')
assert.deepEqual(model.daysForView('2026-08-20', 'work-week', 1).map(model.keyForDate), ['2026-08-17', '2026-08-18', '2026-08-19', '2026-08-20', '2026-08-21'])
assert.deepEqual(model.daysForView('2026-08-20', 'week', 1).map(model.keyForDate), ['2026-08-17', '2026-08-18', '2026-08-19', '2026-08-20', '2026-08-21', '2026-08-22', '2026-08-23'])
assert.equal(model.daysForView('2026-08-20', 'day', 1).map(model.keyForDate)[0], '2026-08-20')
assert.equal(model.viewTitle('2026-08-20', 'day', 1), 'Thursday, August 20')
assert.equal(model.viewTitle('2026-08-20', 'week', 1), 'August 17-23, 2026')
assert.equal(model.eventHour({ start: model.dateTimeIso('2026-08-20', '09:30') }), 9.5)
assert.equal(model.eventEndHour({ start: model.dateTimeIso('2026-08-20', '09:00'), end: model.dateTimeIso('2026-08-20', '15:30') }, '2026-08-20'), 15.5)

const overnightStart = model.dateTimeIso('2026-08-21', '22:00')
const overnightEnd = model.endDateTimeIso('2026-08-21', '22:00', '02:00')
assert.ok(Date.parse(overnightEnd) > Date.parse(overnightStart))
assert.equal(model.localDateKeyFromIso(overnightEnd), '2026-08-22')
assert.equal(model.endDateTimeIso('2026-08-21', '22:00', '22:00'), '')
assert.equal(model.localDateKeyFromIso(model.endDateTimeIso('2026-08-21', '22:00', '23:00')), '2026-08-21')
const overnight = { id: 'night', title: 'Late', start: overnightStart, end: overnightEnd, allDay: false }
assert.deepEqual(model.eventDayKeys(overnight), ['2026-08-21', '2026-08-22'])
assert.equal(model.eventsForDay([overnight], '2026-08-21').length, 1)
assert.equal(model.eventsForDay([overnight], '2026-08-22').length, 1)
assert.equal(model.eventHour(overnight, '2026-08-21'), 22)
assert.equal(model.eventHour(overnight, '2026-08-22'), 0)
assert.equal(model.eventEndHour(overnight, '2026-08-21'), 24)
assert.equal(model.eventEndHour(overnight, '2026-08-22'), 2)
const nightLayoutFri = model.layoutTimedEvents([overnight], '2026-08-21', 0, 24)
const nightLayoutSat = model.layoutTimedEvents([overnight], '2026-08-22', 0, 24)
assert.equal(nightLayoutFri.length, 1)
assert.equal(nightLayoutFri[0].startHour, 22)
assert.equal(nightLayoutFri[0].endHour, 24)
assert.equal(nightLayoutSat.length, 1)
assert.equal(nightLayoutSat[0].startHour, 0)
assert.equal(nightLayoutSat[0].endHour, 2)
assert.equal(model.eventListTime(overnight, '2026-08-22', '12h'), '12 AM')
const midnightEnd = { id: 'mid', title: 'Till midnight', start: model.dateTimeIso('2026-08-21', '22:00'), end: model.dateTimeIso('2026-08-22', '00:00'), allDay: false }
assert.deepEqual(model.eventDayKeys(midnightEnd), ['2026-08-21'])
const multiDay = { id: 'multi', title: 'Trip', start: '2026-08-21', end: '2026-08-24', allDay: true }
assert.deepEqual(model.eventDayKeys(multiDay), ['2026-08-21', '2026-08-22', '2026-08-23'])

const layout = model.layoutTimedEvents([
  { id: 'a', title: 'A', start: model.dateTimeIso('2026-08-20', '09:00'), end: model.dateTimeIso('2026-08-20', '15:30') },
  { id: 'b', title: 'B', start: model.dateTimeIso('2026-08-20', '09:00'), end: model.dateTimeIso('2026-08-20', '10:00') },
  { id: 'c', title: 'C', start: model.dateTimeIso('2026-08-20', '16:00'), end: model.dateTimeIso('2026-08-20', '17:00') }
], '2026-08-20', 7, 21)
assert.equal(layout[0].lanes, 2)
assert.equal(layout[1].lanes, 2)
assert.equal(layout[2].lanes, 1)
assert.notEqual(layout[0].lane, layout[1].lane)

const weekly = model.defaultRecurrence('2026-08-20')
weekly.freq = 'weekly'
weekly.weekdays = [false, false, true, false, true, false, false]
assert.equal(model.serializeRecurrence(weekly), 'FREQ=WEEKLY;BYDAY=TU,TH')
assert.equal(model.summarizeRecurrence(weekly), 'Every week on Tuesday and Thursday')

const daily = model.parseRRule('FREQ=DAILY;INTERVAL=2;COUNT=5', '2026-08-20')
assert.equal(daily.freq, 'daily')
assert.equal(daily.interval, 2)
assert.equal(daily.end, 'count')
assert.equal(model.serializeRecurrence(daily), 'FREQ=DAILY;INTERVAL=2;COUNT=5')
assert.equal(model.summarizeRecurrence(daily), 'Every 2 days, 5 times')

const monthLast = model.parseRRule('FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1;UNTIL=20261218T235959Z', '2026-08-21')
assert.equal(monthLast.monthlyMode, 'byday')
assert.equal(monthLast.bysetpos, -1)
assert.equal(model.serializeRecurrence(monthLast), 'FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1;UNTIL=20261218T235959Z')
assert.match(model.summarizeRecurrence(monthLast), /last Friday/)

const yearly = model.defaultRecurrence('2026-08-21')
yearly.freq = 'yearly'
assert.equal(model.serializeRecurrence(yearly), 'FREQ=YEARLY;BYMONTH=8;BYMONTHDAY=21')
assert.equal(model.summarizeRecurrence(yearly), 'Every year on August 21')

const weekday = model.parseRRule('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', '2026-08-20')
assert.equal(weekday.freq, 'weekday')
assert.equal(model.serializeRecurrence(weekday), 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR')
assert.equal(model.summarizeRecurrence(weekday), 'Every weekday')
assert.equal(model.serializeRecurrence(model.defaultRecurrence('2026-08-20')), '')
assert.equal(model.nextOccurrenceDate('2026-08-21', weekly), '2026-08-25')
assert.equal(model.nextOccurrenceDate('2026-08-25', weekly), '2026-08-25')

const expanded = model.expandRecurringEvent({
  id: 'series',
  title: 'Gym',
  start: model.dateTimeIso('2026-08-25', '05:00'),
  end: model.dateTimeIso('2026-08-25', '06:00')
}, 'FREQ=WEEKLY;BYDAY=TU,TH', '2026-08-23T00:00:00Z', '2026-08-30T00:00:00Z')
assert.equal(expanded.length, 2)
assert.equal(new Date(expanded[0].start).getDay(), 2)
assert.equal(new Date(expanded[1].start).getDay(), 4)

const allDay = model.normalizeEvents([{ id: 'p', title: 'Payday', start: '2026-08-21', end: '2026-08-22', allDay: true }])
assert.equal(model.eventsForDay(allDay, '2026-08-21').length, 1)
assert.equal(model.eventsForDay(allDay, '2026-08-20').length, 0)
assert.equal(model.allDayEventsForDay(allDay, '2026-08-21').length, 1)
assert.equal(model.layoutTimedEvents(allDay, '2026-08-21', 7, 21).length, 0)
assert.equal(model.nextDateKey('2026-08-21'), '2026-08-22')
assert.equal(model.eventDateKey({ start: '2026-08-21', allDay: true }), '2026-08-21')
assert.equal(model.meetingFromText('Join https://zoom.us/j/123456789').provider, 'zoom')
assert.equal(model.meetingFromText('https://meet.google.com/abc-defg-hij').provider, 'meet')
assert.equal(model.meetingFromText('meet.google.com/moy-mhcz-ogi').url, 'https://meet.google.com/moy-mhcz-ogi')
assert.equal(model.meetingFromText('zoom.us/j/123456789').provider, 'zoom')
assert.equal(model.eventMeeting({ location: 'https://teams.microsoft.com/l/meetup-join/x' }).provider, 'teams')
assert.equal(model.meetingProviderLabel('zoom'), 'Zoom')
assert.equal(model.normalizedReminderMinutes(10), 10)
assert.equal(model.normalizedReminderMinutes('off'), 10)
assert.equal(model.normalizedReminderMinutes(0), 0)
const meeting = { uid: 'meet-1', title: 'Standup', start: '2026-08-21T15:10:00Z', allDay: false, meetingUrl: 'https://zoom.us/j/1', meetingProvider: 'zoom' }
assert.equal(model.reminderDue(meeting, 10, Date.parse('2026-08-21T15:00:00Z')), true)
assert.equal(model.reminderDue(meeting, 10, Date.parse('2026-08-21T14:50:00Z')), false)
assert.equal(model.reminderDue(meeting, 10, Date.parse('2026-08-21T15:10:00Z')), false)
assert.equal(model.reminderDue({ ...meeting, allDay: true }, 10, Date.parse('2026-08-21T15:00:00Z')), false)
assert.equal(model.dueReminders([meeting], 10, {}, Date.parse('2026-08-21T15:00:00Z')).length, 1)
assert.equal(model.dueReminders([meeting], 10, { [model.reminderKey(meeting, 10)]: true }, Date.parse('2026-08-21T15:00:00Z')).length, 0)
assert.ok(model.reminderBody(meeting, '12h').indexOf('Join Zoom') >= 0)
const pruned = model.pruneFiredKeys({ 'old|2026-08-01T00:00:00Z|10': true, [model.reminderKey(meeting, 10)]: true }, Date.parse('2026-08-21T15:00:00Z'))
assert.equal(pruned['old|2026-08-01T00:00:00Z|10'], undefined)
assert.equal(pruned[model.reminderKey(meeting, 10)], true)
assert.equal(model.monthlyOccurrenceOptions('2026-08-28').some(option => option.value === 'byday:-1'), true)

console.log('ok - calendar model')
