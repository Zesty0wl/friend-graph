# Changelog

## 0.3.1 (10 November 2026)

- Shared videos now run for as long as each picture needs. The timeline plays its whole story from the first message to today, at the normal pace; the circle runs 14 seconds, the weekly chart 8 and the iris 12.
- When a story runs longer than a minute, the share sheet offers shorter lengths and a choice of keeping the most recent part or the beginning. It starts on 60 seconds of the most recent.
- The share sheet shows how long the video will be before you make it.
- My Film now gives every line time to be read: each chapter lasts as long as its caption needs, captions are one short sentence each, and the film runs a little under 50 seconds.
- On the moving timeline, each line now bends to meet its face, so a face that is moved clear of its neighbours never comes away from its line.
- The film's closing line holds for several seconds and fades out slowly with the music, where it used to stop abruptly.

## 0.3.0 (10 November 2026)

### Drawn on the GPU
- Every picture, the share cards and the film are now drawn with Metal. Strands are shaped on the GPU, and shapes that never change (the weekly ribbons) stay in GPU memory.
- The live pictures use a third to a half of the processor time they did. My circle went from about 43% of one core to about 12%.
- The film renders in about 7 seconds instead of 12.

### Fixes
- In the moving timeline, a crowded stack of faces now closes up to stay inside the picture.

## 0.2.0 (10 November 2026)

### My Film
- A 30 second film of your year in six chapters, tall for stories, with music made by the app. Three optional questions first: a word for the year, someone to thank, and the best moment.
- The music follows the picture: a note plays as each number, person and line appears.
- Captions are written on device by Apple Intelligence from your own figures, with the same checks as the side panel.
- Everyone in the film is named, by first name where space is tight, and never by initials alone. Someone with no photo is shown as a simple figure.

### What my Mac knows
- Each strand now carries macOS's own name for it, written along the strand.

### Lighter on your Mac
- Pictures stop animating while another app is in front.
- Each picture redraws only as often as it needs to. "What my Mac knows" uses about a tenth of the processor time it did.

### Fixes
- Requests to the on-device model give up after a few seconds, so a stall can never hold up the app.
- Two exports at the same time no longer overwrite each other's files.
- Contact photos are matched by phone number and address as well as by name.

## 0.1 (10 November 2026)

First release.

### Pictures
- My circle: three rings that turn at their own pace, a strand to each person, and messages travelling along the strands at the pace you really reply. Drag to spin, or drag someone to another ring.
- My year: a moving timeline of every day your messages cover. Drag to move through time.
- Week by week: 53 weeks of conversation with your ten closest people.
- What my Mac knows: every view macOS keeps over its knowledge graph. The dot at the tip of each strand grows with how much it holds, and a hollow tip is empty.

### Side panel
- Key figures and small charts for each picture and each person: who sends more, how quickly each of you replies, the last twelve months, and by day of the week.
- A short note written on device by Apple Intelligence from those figures. A note is only shown if every name and number in it comes from the figures; otherwise plain sentences are shown.

### Your people
- Closeness score from reply speed, balance, staying power and calls, with a small boost for Family Sharing.
- Reads the Apple Intelligence interaction log, Messages, WhatsApp, call history and Contacts. Falls back to Messages and WhatsApp when the log is missing.
- One confirmation screen for relationships, with In memory and Leave out.
- Your own numbers and addresses are never shown as a contact.

### Sharing
- Pictures as PNG, square or tall, or a 10 second video.
- Names as full, first names, initials or none; photos shown or hidden. Starts on initials with photos hidden.

### Other
- Try it with made-up people, without granting access.
- In the moving timeline, faces that would overlap are eased apart so every name can be read.
- Requires macOS 27.
