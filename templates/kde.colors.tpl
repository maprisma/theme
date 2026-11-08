# Maprisma Plasma color scheme; surface mixes adapt to light and dark palettes.
[ColorEffects:Disabled]
Color={{ mix_rgb background foreground 20% }}
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color={{ mix_rgb background foreground 40% }}
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundNormal={{ mix_rgb background foreground 6% }}
BackgroundAlternate={{ mix_rgb background foreground 10% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Complementary]
BackgroundNormal={{ mix_rgb background foreground 10% }}
BackgroundAlternate={{ mix_rgb background foreground 14% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Header]
BackgroundNormal={{ mix_rgb background foreground 6% }}
BackgroundAlternate={{ mix_rgb background foreground 10% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Header][Inactive]
BackgroundNormal={{ mix_rgb background foreground 3% }}
BackgroundAlternate={{ mix_rgb background foreground 7% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Selection]
BackgroundNormal={{ mix_rgb background accent 30% }}
BackgroundAlternate={{ mix_rgb background accent 40% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Tooltip]
BackgroundNormal={{ mix_rgb background foreground 8% }}
BackgroundAlternate={{ mix_rgb background foreground 12% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:View]
BackgroundNormal={{ mix_rgb background foreground 0% }}
BackgroundAlternate={{ mix_rgb background foreground 4% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[Colors:Window]
BackgroundNormal={{ mix_rgb background foreground 3% }}
BackgroundAlternate={{ mix_rgb background foreground 7% }}
DecorationFocus={{ accent_rgb }}
DecorationHover={{ mix_rgb background accent 70% }}
ForegroundActive={{ accent_rgb }}
ForegroundInactive={{ mix_rgb foreground background 35% }}
ForegroundLink={{ blue_rgb }}
ForegroundNegative={{ red_rgb }}
ForegroundNeutral={{ yellow_rgb }}
ForegroundNormal={{ foreground_rgb }}
ForegroundPositive={{ green_rgb }}
ForegroundVisited={{ magenta_rgb }}

[General]
ColorScheme=@SCHEME_NAME@
Name=@SCHEME_NAME@

[KDE]
contrast=4

[WM]
activeBackground={{ mix_rgb background foreground 6% }}
activeForeground={{ foreground_rgb }}
activeBlend={{ foreground_rgb }}
inactiveBackground={{ mix_rgb background foreground 3% }}
inactiveForeground={{ mix_rgb foreground background 35% }}
inactiveBlend={{ mix_rgb foreground background 35% }}
