/*
 * General settings page. Plasma auto-saves any property named cfg_<entry>
 * back to the schema in config/main.xml — the aliases below are the whole
 * wiring, no save/load code needed.
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_updateInterval: intervalSpin.value
    property alias cfg_showAllBuckets: allBucketsCheck.checked
    property alias cfg_notificationsEnabled: notifyCheck.checked
    property alias cfg_warnThreshold: warnSpin.value
    property alias cfg_critThreshold: critSpin.value

    QQC2.SpinBox {
        id: intervalSpin
        Kirigami.FormData.label: i18n("Update every:")
        // Stored as seconds (60–1800) but shown/edited in whole minutes.
        from: 60; to: 1800; stepSize: 60
        textFromValue: (v) => i18np("%1 minute", "%1 minutes", Math.round(v / 60))
        valueFromText: (t) => Math.max(1, Math.round(parseFloat(t) || 1)) * 60
    }

    QQC2.CheckBox {
        id: allBucketsCheck
        Kirigami.FormData.label: i18n("Details popup:")
        text: i18n("Show per-model usage buckets")
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.CheckBox {
        id: notifyCheck
        Kirigami.FormData.label: i18n("Notifications:")
        text: i18n("Notify when usage crosses a threshold")
    }

    QQC2.SpinBox {
        id: warnSpin
        Kirigami.FormData.label: i18n("Warning at:")
        enabled: notifyCheck.checked
        from: 1; to: critSpin.value
        textFromValue: (v) => v + "%"
        valueFromText: (t) => parseInt(t)
    }

    QQC2.SpinBox {
        id: critSpin
        Kirigami.FormData.label: i18n("Critical at:")
        enabled: notifyCheck.checked
        from: warnSpin.value; to: 100
        textFromValue: (v) => v + "%"
        valueFromText: (t) => parseInt(t)
    }
}
