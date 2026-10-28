---
title: Licensing
nav_order: 2.5
---

# Licensing and activation

This page is about the Mac app from Gumroad. A build you compile yourself has no license
check, and the iPhone app is free.

## The trial

Spiel works fully for 14 days from the first time you open it, and the menu shows how many
days are left. When the trial ends, starting Dictation or Listen opens the **License**
window instead. Your transcripts, History and Vocabulary stay where they are.

## Activate a key

1. Buy Spiel on [Gumroad](https://morehavoc.gumroad.com/l/spiel). The key is in your receipt
   email, and in your Gumroad library if you have a Gumroad account.
2. In Spiel's menu, choose **Enter License Key…**.
3. Paste the key and click **Activate**. This needs an internet connection.

After that the menu item becomes **License…**. The License window shows the last four characters of your
key (`Licensed ****ABCD`) and a **Change Key** button.

## Two Macs per key

Each key has 2 seats, and each activation uses one.

- Activating on a new Mac uses a seat.
- Entering the key again on a Mac where it's already active doesn't use another one.
- Spiel keeps the key in `~/Library/Application Support/Spiel/license.json`. If you delete
  that folder, entering the key again on the same Mac uses a seat.
- Removing Spiel from a Mac doesn't give the seat back.

If you need a seat freed (a new or replaced Mac, say), email me at
[spiel@christophermoravec.com](mailto:spiel@christophermoravec.com) and I'll reset it.

## If activation fails

The License window says why:

- **"This key is already used on 2 Macs."** Both seats are in use. Email me for a reset.
- **"That key is not valid for Spiel."** Check that you copied the whole key from the
  receipt with nothing extra. You'll also see this for a key from a different Gumroad
  product.
- **"Could not reach Gumroad. Try again."** Check your internet connection.
- **"This purchase was refunded"**, **"charged back"** or **"This key has been disabled."**
  The key no longer works.

Rarely, you may see **"That key is for a different product."** It means the same thing as
"not valid": the key belongs to something else.

## Refunds

Within 14 days of purchase, email me at
[spiel@christophermoravec.com](mailto:spiel@christophermoravec.com) or reply to your Gumroad
receipt.

## Advanced: the weekly check

About once a week, Spiel checks the key with Gumroad, sending only the key and Spiel's
product ID. If Spiel can't reach Gumroad, nothing changes and it tries again a day later,
so working offline is fine.

A key is turned off only when Gumroad reports it refunded, charged back or disabled on two
checks in a row, so a refunded key stops working within about two weeks. A
session that's already running is never cut off.

When a key is turned off or the trial is over, the `spiel` command stops too; see
[Command line](command-line.md#scripting).
