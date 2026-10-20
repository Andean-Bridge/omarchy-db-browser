pragma Singleton
import QtQuick
QtObject {
  property int cornerRadius: 6
  property var font: ({ family: "sans-serif", bodySmall: 13, body: 14, caption: 12, title: 16, heading: 18 })
}
