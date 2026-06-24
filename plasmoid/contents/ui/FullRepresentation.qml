/*
 * Claudometer — FullRepresentation.qml
 *
 * The popup (panel) / always-on view (desktop): one row per usage bucket,
 * an optional extra-usage credits row, and a footer with freshness + refresh.
 * All state lives on the root PlasmoidItem (main.qml); this file only renders.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: full
    collapseMarginsHint: true

    // Size the popup to whichever view is actually showing, so the placeholder
    // (a tall icon + text + button) is never clipped by the frame.
    readonly property int framePad: Kirigami.Units.largeSpacing * 2
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.preferredWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 12
    Layout.preferredHeight: framePad + (root.hasData ? content.implicitHeight
                                                      : placeholder.implicitHeight)

    // Error state with no data at all → a friendly placeholder instead of
    // empty bars pretending everything is fine. Equal-weight spacers above
    // and below center it vertically with matching breathing room
    // (anchors.centerIn misbehaves inside a Representation).
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        visible: !root.hasData

        Item { Layout.fillHeight: true }
        PlasmaExtras.PlaceholderMessage {
            id: placeholder
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            iconName: root.errorType ? "data-warning" : "view-refresh"
            text: root.errorType ? i18n("No usage data") : i18n("Loading…")
            explanation: root.rateLimited
                ? i18n("%1\nRetrying in %2.", root.errorMessage, root.fmtCooldown())
                : root.errorMessage
            helpfulAction: Kirigami.Action {
                icon.name: "view-refresh"
                text: i18n("Retry")
                enabled: !root.rateLimited
                onTriggered: root.fetchNow(true)
            }
        }
        Item { Layout.fillHeight: true }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        visible: root.hasData
        spacing: Kirigami.Units.smallSpacing

        // One block per bucket: "Session            35%"
        //                       [████████░░░░░░░░░░░░░]
        //                       resets in 2h 14m
        Repeater {
            model: root.visibleBuckets
            delegate: ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing / 2

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents3.Label {
                        text: modelData.label
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents3.Label {
                        text: Math.round(modelData.pct) + "%"
                        font.weight: Font.Bold
                        color: root.barColor(modelData.pct)
                    }
                }
                PlasmaComponents3.ProgressBar {
                    Layout.fillWidth: true
                    from: 0; to: 100
                    value: modelData.pct
                }
                PlasmaComponents3.Label {
                    text: root.fmtCountdown(modelData.resets_at)
                    visible: text !== ""
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                }
                Item { height: Kirigami.Units.smallSpacing }  // block gap
            }
        }

        // Pay-per-use credits, only when the account has it enabled.
        RowLayout {
            Layout.fillWidth: true
            visible: root.extraUsage.enabled === true
            PlasmaComponents3.Label {
                text: i18n("Extra usage")
                font.weight: Font.Medium
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                text: {
                    const used = root.extraUsage.used_credits
                    const limit = root.extraUsage.monthly_limit
                    if (used === null || used === undefined) return ""
                    return limit ? i18n("$%1 of $%2", used.toFixed(2), limit)
                                 : i18n("$%1 used", used.toFixed(2))
                }
                opacity: 0.8
            }
        }

        // Transient error while we still have (possibly stale) data.
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            visible: root.errorType !== "" && root.hasData
            text: "⚠ " + root.errorMessage
            wrapMode: Text.WordWrap
            color: Kirigami.Theme.neutralTextColor
            font: Kirigami.Theme.smallFont
        }

        Item { Layout.fillHeight: true }

        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label {
                text: root.rateLimited
                    ? i18n("Rate limited — retrying in %1", root.fmtCooldown())
                    : root.stale
                        ? i18n("Stale — updated %1", root.fmtAgo(root.lastSuccess))
                        : i18n("Updated %1", root.fmtAgo(root.lastSuccess))
                opacity: 0.6
                font: Kirigami.Theme.smallFont
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh"
                display: PlasmaComponents3.AbstractButton.IconOnly
                // Disabled during a server cooldown so the user can't re-trip it.
                enabled: !root.rateLimited
                text: root.rateLimited ? i18n("Rate limited — retry in %1", root.fmtCooldown())
                                       : i18n("Refresh")
                onClicked: root.fetchNow(true)
                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered
            }
        }
    }
}
