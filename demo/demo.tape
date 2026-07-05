# vhs tape for the maccal CLI demo gif (assets/demo-cli.gif).
# Regenerate:  PATH="$PWD/demo/bin:$PATH" vhs demo/demo.tape
# Uses demo/bin/maccal — a mock that prints fictional output and never touches
# the real calendar — so the gif is safe to publish.
Output "assets/demo-cli.gif"

Set Shell "bash"
Set FontSize 18
Set Width 1080
Set Height 720
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 45ms

Hide
Type "PS1='$ '; clear"
Enter
Sleep 300ms
Show

Sleep 600ms
Type "maccal calendars"
Enter
Sleep 1.6s

Type "maccal agenda"
Enter
Sleep 2.2s

Type "maccal show a1b2c3d"
Enter
Sleep 2.4s

Type "maccal free --duration 1h"
Enter
Sleep 2.2s
