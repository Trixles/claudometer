/*
 * Claudometer — main.qml
 *
 * Root of the plasmoid. Owns ALL state and the polling loop:
 *   Timer → run bundled helper via the "executable" engine → parse stdout
 * The compact (panel) representation lives inline here; the popup is in
 * FullRepresentation.qml.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---- state ------------------------------------------------------------
    property var buckets: []          // [{id,label,pct,resets_at}]
    property var extraUsage: ({})     // {enabled, used_credits, monthly_limit}
    property bool hasData: false      // ever had a successful fetch?
    property string errorType: ""     // "" = healthy
    property string errorMessage: ""
    property double lastSuccess: 0    // ms epoch of last good fetch
    property double lastAttempt: 0    // ms epoch of last fetch attempt
    property double cooldownUntil: 0  // ms epoch; no fetch before this (server 429)
    property int retryAfterSec: 0     // server's stated wait, for display
    property var notified: ({})       // per-bucket notification latches

    readonly property int intervalMs: Plasmoid.configuration.updateInterval * 1000

    // Data is "stale" when the last success is older than 3 polling intervals.
    readonly property bool stale:
        hasData && (now - lastSuccess > 3 * intervalMs)

    // True while we're honoring a server-mandated 429 cooldown. Driven by
    // `now` (the 30 s clock) so the UI counts down on its own.
    readonly property bool rateLimited: now < cooldownUntil
    readonly property int cooldownLeftSec: Math.max(0, Math.round((cooldownUntil - now) / 1000))

    // A coarse clock for countdown labels ("resets in 2h 14m") so they tick
    // without re-fetching anything.
    property double now: Date.now()
    Timer { interval: 30000; running: true; repeat: true
            onTriggered: root.now = Date.now() }

    // The two headline buckets, for the panel bars and tooltip.
    readonly property var sessionBucket: findBucket("five_hour")
    readonly property var weeklyBucket: findBucket("seven_day")
    function findBucket(id) {
        for (let i = 0; i < buckets.length; i++)
            if (buckets[i].id === id) return buckets[i]
        return null
    }

    // Buckets shown in the popup: all of them, or just the two headliners.
    readonly property var visibleBuckets: Plasmoid.configuration.showAllBuckets
        ? buckets
        : buckets.filter(b => b.id === "five_hour" || b.id === "seven_day")

    // ---- colors -----------------------------------------------------------
    // Native by default: follow the Plasma theme. Custom colors are opt-in.
    function barColor(pct) {
        const cfg = Plasmoid.configuration
        if (pct >= cfg.critThreshold)
            return cfg.useCustomColors ? cfg.colorCritical
                                       : Kirigami.Theme.negativeTextColor
        if (pct >= cfg.warnThreshold)
            return cfg.useCustomColors ? cfg.colorWarning
                                       : Kirigami.Theme.neutralTextColor
        return cfg.useCustomColors ? cfg.colorNormal
                                   : Kirigami.Theme.highlightColor
    }

    // ---- fetching ---------------------------------------------------------
    // One fixed command, nothing interpolated into it (it runs via /bin/sh).
    readonly property string helperCmd: "python3 '"
        + Qt.resolvedUrl("../scripts/claudometer.py").toString().replace("file://", "")
        + "'"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source)  // one-shot: stop the engine re-running it
            if (source === root.helperCmd)
                root.handleResult(data["stdout"], data["exit code"])
            // notify-send sources need no result handling
        }
    }

    function fetchNow(force) {
        // Server-mandated 429 cooldown is absolute — it gates even manual
        // refreshes, so we can never re-trip the limit by retrying too early.
        if (Date.now() < cooldownUntil) return
        // Otherwise throttle bursts (timer + popup-open may coincide).
        if (!force && Date.now() - lastAttempt < 60000) return
        lastAttempt = Date.now()
        exec.connectSource(helperCmd)
    }

    // Constant cadence; fetchNow() self-gates on the cooldown, so a long 429
    // wait simply means the next few ticks no-op until the server is ready.
    Timer {
        interval: root.intervalMs
        running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.fetchNow(false)
    }

    // Refresh when the popup opens, so the details are current on click.
    onExpandedChanged: if (expanded) fetchNow(false)

    function handleResult(stdout, exitCode) {
        let payload
        try {
            payload = JSON.parse(stdout)
        } catch (e) {
            setError("helper", "Helper produced invalid output (exit " + exitCode + ")")
            return
        }
        if (!payload.ok) {
            setError(payload.error_type, payload.error, payload.retry_after)
            return
        }
        errorType = ""
        errorMessage = ""
        cooldownUntil = 0
        retryAfterSec = 0
        buckets = payload.buckets
        extraUsage = payload.extra_usage || {}
        hasData = true
        lastSuccess = Date.now()
        now = Date.now()
        checkNotifications()
    }

    function setError(type, message, retryAfter) {
        errorType = type
        errorMessage = message
        // Rate limited → wait exactly as long as the server asked (plus a
        // 15 s margin). Falls back to 15 min if the header was missing.
        if (type === "rate_limited") {
            var wait = (retryAfter && retryAfter > 0) ? retryAfter : 900
            retryAfterSec = wait
            cooldownUntil = Date.now() + (wait + 15) * 1000
            now = Date.now()  // refresh derived rateLimited/cooldownLeftSec now
        }
    }

    // ---- notifications ----------------------------------------------------
    // Fixed message strings + integer percentages only — nothing from the
    // API ever reaches the shell, so injection is structurally impossible.
    function checkNotifications() {
        if (!Plasmoid.configuration.notificationsEnabled) return
        const cfg = Plasmoid.configuration
        const watch = { five_hour: "Session limit", seven_day: "Weekly limit" }
        for (const id in watch) {
            const b = findBucket(id)
            if (!b) continue
            const pct = Math.round(b.pct)
            const state = notified[id] || ""
            if (pct >= cfg.critThreshold && state !== "crit") {
                notify("dialog-error", watch[id] + " at " + pct + "%", "critical")
                notified[id] = "crit"
            } else if (pct >= cfg.warnThreshold && state === "") {
                notify("dialog-warning", watch[id] + " at " + pct + "%", "normal")
                notified[id] = "warn"
            } else if (pct < cfg.warnThreshold) {
                notified[id] = ""   // reset latch after the limit resets
            }
        }
    }
    function notify(icon, body, urgency) {
        exec.connectSource("notify-send -a Claudometer -i " + icon
                           + " -u " + urgency + " 'Claude usage' '" + body + "'")
    }

    // ---- formatting helpers (shared with FullRepresentation) ---------------
    function fmtCountdown(resetsAt) {
        if (!resetsAt) return ""
        const ms = new Date(resetsAt).getTime() - now
        if (isNaN(ms) || ms <= 0) return i18n("resets soon")
        const min = Math.ceil(ms / 60000)
        if (min < 60) return i18n("resets in %1m", min)
        const h = Math.floor(min / 60)
        if (h < 48) return i18n("resets in %1h %2m", h, min % 60)
        return i18n("resets in %1d %2h", Math.floor(h / 24), h % 24)
    }
    function fmtAgo(t) {
        if (!t) return i18n("never")
        const s = Math.max(0, Math.round((now - t) / 1000))
        if (s < 60) return i18n("%1s ago", s)
        return i18n("%1m ago", Math.round(s / 60))
    }
    // Bare duration ("45s" / "8m") — callers supply the surrounding phrasing.
    function fmtCooldown() {
        const s = cooldownLeftSec
        if (s <= 0) return ""
        return s < 60 ? i18n("%1s", s) : i18n("%1m", Math.ceil(s / 60))
    }

    // ---- plasmoid chrome ---------------------------------------------------
    Plasmoid.icon: "speedometer"
    toolTipMainText: i18n("Claude usage")
    toolTipSubText: {
        if (errorType && !hasData)
            return rateLimited ? i18n("%1 Retrying in %2.", errorMessage, fmtCooldown())
                               : errorMessage
        if (!hasData) return i18n("Waiting for first update…")
        let lines = []
        if (sessionBucket)
            lines.push(i18n("Session %1% — %2", Math.round(sessionBucket.pct),
                            fmtCountdown(sessionBucket.resets_at)))
        if (weeklyBucket)
            lines.push(i18n("Week %1% — %2", Math.round(weeklyBucket.pct),
                            fmtCountdown(weeklyBucket.resets_at)))
        if (rateLimited) lines.push(i18n("⚠ Rate limited — retrying in %1", fmtCooldown()))
        else if (stale) lines.push(i18n("⚠ data is stale (%1)", fmtAgo(lastSuccess)))
        else if (errorType) lines.push("⚠ " + errorMessage)
        return lines.join("\n")
    }

    // ---- compact representation (the panel face) ----------------------------
    compactRepresentation: MouseArea {
        id: compact
        onClicked: root.expanded = !root.expanded

        Layout.minimumWidth: Kirigami.Units.gridUnit * 3
        Layout.preferredWidth: Kirigami.Units.gridUnit * 4

        // Dim the bars when data is stale or erroring; badge explains why.
        opacity: (root.stale || (root.errorType && !root.hasData)) ? 0.5 : 1.0

        ColumnLayout {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.smallSpacing * 2
            spacing: Kirigami.Units.smallSpacing / 2

            Repeater {
                model: [
                    { tag: "5h", bucket: root.sessionBucket },
                    { tag: "7d", bucket: root.weeklyBucket },
                ]
                delegate: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    Text {
                        text: modelData.tag
                        color: Kirigami.Theme.textColor
                        opacity: 0.7
                        font.pixelSize: Math.max(8, compact.height * 0.28)
                    }
                    // Track + fill: a slim rounded bar drawn by hand —
                    // lighter than a full ProgressBar control in a panel.
                    Item {
                        Layout.fillWidth: true
                        height: Math.max(4, compact.height * 0.18)
                        // translucent track…
                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: Kirigami.Theme.textColor
                            opacity: 0.25
                        }
                        // …with a colored fill on top
                        Rectangle {
                            height: parent.height
                            radius: height / 2
                            width: parent.width *
                                Math.min(1, (modelData.bucket ? modelData.bucket.pct : 0) / 100)
                            color: root.barColor(modelData.bucket ? modelData.bucket.pct : 0)
                            Behavior on width { NumberAnimation { duration: 300 } }
                        }
                    }
                }
            }
        }

        // Small warning emblem when something is wrong.
        Kirigami.Icon {
            visible: root.errorType !== "" || root.stale
            source: "emblem-warning"
            width: Kirigami.Units.iconSizes.small
            height: width
            anchors.right: parent.right
            anchors.bottom: parent.bottom
        }
    }

    fullRepresentation: FullRepresentation {}
}
