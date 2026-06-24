/*  maxMouse auto-start
    --------------------------------------------------------------------------
    Copy this file to your 3ds Max user startup scripts folder so maxMouse
    loads automatically every time Max launches, e.g.:

      C:\Users\<you>\AppData\Local\Autodesk\3dsMax\<version>\ENU\scripts\startup\

    EDIT the path below to point at where you keep maxMouse.ms.
    --------------------------------------------------------------------------
*/

(
    -- >>> EDIT THIS to the full path of maxMouse.ms on your machine <<<
    local maxMousePath = @"C:\maxMouse\src\maxMouse.ms"

    if (doesFileExist maxMousePath) then
        fileIn maxMousePath
    else
        format "maxMouse startup: file not found - %\n" maxMousePath
)
