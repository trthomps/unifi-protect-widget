import QtQuick

// Events for a ListView, updated in place so the list keeps its scroll position and rows when
// an event changes or arrives (assigning a new JS array resets a ListView). Each row holds the
// event as JSON, since ListModel would turn its arrays into nested models.
ListModel {
    id: model

    property var events: []

    onEventsChanged: sync()
    Component.onCompleted: sync()

    function sync() {
        const list = events || []
        for (let i = 0; i < list.length; i++) {
            const id = list[i].id
            const json = JSON.stringify(list[i])
            if (i < count && get(i).eventId === id) {
                if (get(i).json !== json) setProperty(i, "json", json)
                continue
            }
            let j = -1
            for (let k = i + 1; k < count; k++) if (get(k).eventId === id) { j = k; break }
            if (j >= 0) {
                move(j, i, 1)
                if (get(i).json !== json) setProperty(i, "json", json)
            } else {
                insert(i, { eventId: id, json: json })
            }
        }
        if (count > list.length) remove(list.length, count - list.length)
    }
}
