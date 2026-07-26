# EnemyClassicBuffs

EnemyClassicBuffs is a configurable aura display addon for **World of Warcraft Classic Era**.

It shows buffs and debuffs on the currently selected target by combining aura data from:

- The official Blizzard aura API
- Combat-log-based aura tracking derived from ClassicAuraDurations

This allows the addon to supplement hostile aura information that the Blizzard API may hide. API and combat-log records are merged by spell ID to prevent duplicate icons and to fill in missing duration information whenever possible.

## Features

- Separate frames for target buffs and debuffs
- Supports hostile targets, friendly targets, the player, and duel opponents
- Combat-log reconstruction for hidden hostile and duel-opponent auras
- Merges Blizzard API and combat-log aura records
- Avoids duplicate icons by matching spell IDs
- Fills in missing aura durations when combat-log timing is available
- Configurable icons per row
- Configurable number of rows
- Independently adjustable buff and debuff icon sizes
- Independently adjustable cooldown font sizes
- Outlined cooldown text for improved readability
- Reverse cooldown swipe animation
- Stack-count display
- Spell tooltips
- Combat-log-only auras marked with a blue `L`
- Transparent frame backgrounds
- Left-to-right icon arrangement
- Independently movable buff and debuff frames
- 25 preview auras while positioning each frame
- Saved frame positions and settings
- Blizzard Settings integration
- Embedded and isolated combat-log tracking library
- No active ClassicAuraDurations installation required

## Installation

1. Download or clone this repository.
2. Copy the `EnemyClassicBuffs` folder into:

   ```text
   World of Warcraft/_classic_era_/Interface/AddOns/
   ```

3. Restart World of Warcraft if the client was already running.
4. Enable **EnemyClassicBuffs** on the character-selection AddOns screen.

The final directory should look like:

```text
Interface/AddOns/EnemyClassicBuffs/EnemyClassicBuffs.toc
```

## Configuration

Open the Blizzard AddOn settings and select **EnemyClassicBuffs**, or enter:

```text
/ecb
```

The buff and debuff frames can be configured independently.

Available settings include:

- Buffs or debuffs per row
- Number of rows
- Icon size
- Cooldown font size
- Frame unlock and positioning mode

When a frame is unlocked, it displays 25 test auras and can be moved by dragging its title.

Lock the frame again after positioning it. The preview auras will disappear, and the frame position will remain saved.

## Slash Commands

```text
/ecb
```

Opens the EnemyClassicBuffs settings.

```text
/ecb buffs
```

Toggles the buff-frame positioning preview.

```text
/ecb debuffs
```

Toggles the debuff-frame positioning preview.

## Aura Sources

### Blizzard API

The Blizzard API is used as the primary source for all visible target auras. This includes:

- Hostile targets
- Friendly players
- The player's own character when self-targeted
- Duel opponents

### Combat Log

Combat-log tracking supplements aura information for attackable targets when the Blizzard API does not expose the complete aura list.

Combat-log-only auras are marked with a blue `L` in the upper-left corner of the icon.

The combat log may also provide duration information when the API reports an aura with a duration of zero.

## Duel Support

Same-faction duel opponents may still be classified as friendly by parts of the WoW API. EnemyClassicBuffs uses attackability checks to recognize an active duel opponent and enable combat-log reconstruction for that target.

An aura that was already active before the duel began may not be reconstructable until it is applied or refreshed during the duel.

## Display Behavior

- Icons are arranged from left to right.
- Additional rows are filled from top to bottom.
- Buff and debuff frames remain hidden when they contain no auras.
- Frames have transparent backgrounds.
- Timed auras display cooldown text and a reverse swipe animation.
- Permanent or unknown-duration auras are shown without a countdown.
- Combat-log entries are automatically removed after their tracked duration expires.

## Limitations

Combat-log reconstruction is only possible when:

- The aura application appears in the combat log.
- The spell is known to the embedded duration database.
- The addon observes the application or refresh event.

Auras hidden from both the Blizzard API and the combat log cannot be detected.

Combat-log tracking cannot reliably reconstruct an aura that was already active before the addon began observing the target. It generally becomes available after the aura is applied or refreshed.

Some third-party cooldown addons, such as OmniCC, may replace the native cooldown text. In that case, cooldown font settings from the third-party addon may take precedence.

## Compatibility

- World of Warcraft Classic Era
- Interface version `11509`
- ElvUI-compatible because EnemyClassicBuffs uses independent frames

## Credits

EnemyClassicBuffs uses an embedded and isolated version of the combat-log duration tracking approach from **ClassicAuraDurations** and **LibClassicDurations**.

## Author

**Patzê-Firemaw**
