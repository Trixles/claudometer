/*
 * Appearance settings. Theme colors by default; custom colors are opt-in
 * and use KDE's native color picker dialog (no hex strings to type).
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQControls

Kirigami.FormLayout {
    property alias cfg_useCustomColors: customCheck.checked
    property alias cfg_colorNormal: normalButton.color
    property alias cfg_colorWarning: warningButton.color
    property alias cfg_colorCritical: criticalButton.color

    QQC2.CheckBox {
        id: customCheck
        Kirigami.FormData.label: i18n("Colors:")
        text: i18n("Use custom colors")
    }

    KQControls.ColorButton {
        id: normalButton
        Kirigami.FormData.label: i18n("Normal:")
        enabled: customCheck.checked
        showAlphaChannel: false
    }
    KQControls.ColorButton {
        id: warningButton
        Kirigami.FormData.label: i18n("Warning:")
        enabled: customCheck.checked
        showAlphaChannel: false
    }
    KQControls.ColorButton {
        id: criticalButton
        Kirigami.FormData.label: i18n("Critical:")
        enabled: customCheck.checked
        showAlphaChannel: false
    }
}
