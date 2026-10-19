pragma Singleton
import QtQuick

// The shell's Style, as far as Omabib uses it: space() scales a pixel size by
// the shell's UI scale, which outside the shell is 1.
QtObject {
    function space(px) { var n = Number(px); return n <= 0 ? 0 : Math.max(1, Math.round(n)) }
}
