# RoomTwin

Real-time room scanning on an iPhone or iPad with LiDAR. It implements the mesh representation from
Dong et al., *An Efficient Volumetric Mesh Representation for Real-time Scene Reconstruction using
Spatial Hashing* (ICRA 2018), in Metal.

- **Spatial hashing:** space is split into 8×8×8 blocks of cubes, allocated only near surfaces.
- **Mesh stored in the volume:** each cube owns the 3 edges leaving its min corner, so every vertex
  is stored once and found with one hash lookup.
- **Incremental meshing:** only blocks touched by the current frame are remeshed. Cubes whose type
  didn't change keep their triangles, and only their vertices move.
- **GPU memory pools:** vertices and triangles live in pools with free lists and reference counts.
  The pools are drawn directly, with no per-frame mesh extraction.

## Run it on your iPhone

1. Open `RoomTwin.xcodeproj` in Xcode.
2. Select the **RoomTwin** target, open **Signing & Capabilities**, and pick your **Team**. A free
   personal team works. If Xcode says the bundle identifier is taken, change
   `dev.bugatti.RoomTwin` to something unique.
3. Connect the iPhone. On the phone, turn on **Settings › Privacy & Security › Developer Mode**.
4. Pick the phone as the run destination and press **Run**. With a free team, the first launch asks
   you to trust the developer under **Settings › General › VPN & Device Management**.

You need a device with LiDAR: iPhone 12 Pro or a later Pro model, or an iPad Pro.

**In the app:** the camera view opens paused. Tap **Start Scan** and pick the kind of scan:
**Detailed Mesh** (below), **Room Layout** (RoomPlan, further down), **Hybrid**, or
**SAM Furniture**.

With Detailed Mesh, move slowly and the mesh builds up over the camera view. Frames are only added
while ARKit is tracking normally; otherwise a hint above the buttons says why (moving too fast, not
enough light or texture, still starting up).

- **Pause/Scan** stops or resumes fusion.
- **Color/Shaded/Camera** switches how the mesh is shown.
- **Reset** clears the scan and goes back to Start Scan, so you can pick either kind again.
- **View** pauses scanning and opens the scan in 3D on the phone, with nothing to export first.
  **Orbit** circles the room like a dollhouse: the near walls and the ceiling drop away. Drag to
  turn, pinch to zoom, and use two fingers to pan. **Walk** puts you where the phone was when you
  tapped View, at the same height. The stick moves you, and dragging anywhere else turns your
  head. The orange marker in Orbit shows where you are. **Close** goes back to the camera, and
  **Scan** carries on adding to the same scan. **AR Edit** reuses the live ARKit/LiDAR session and
  overlays the editable furniture at its scanned world position. Turn on **Hand Tracking**, aim
  the cursor at a piece, pinch thumb and index finger to grab, move your hand, and open the pinch
  to release. Undo/redo records each released hand move. **Talk** lets you add furniture by voice
  (see below).
- **Export** writes the scan in two formats and opens the share sheet:
  - `.usdz` previews with Quick Look (spacebar in Finder, or tap it in the Files app).
  - `.ply` is for MeshLab or Blender.

  Saved scans also appear in **Files › On My iPhone › RoomTwin**.

## Accounts

The app opens on a login screen: a username and password, nothing else. **New here? Create an
account** makes one. The session stays in the phone's Keychain, so you only log in once. The
person icon at the top left shows who's logged in and has **Log Out**.

An account holds the objects and room layouts you scan. After Photo or Walk Around builds a model,
**Save to My Objects** names it and uploads it with its photo to the owner's Google Drive.
SAM replacements use this same storage automatically. In a room preview, **My Objects**
lists them; tap one and it stands on the floor where you're looking. The voice agent doesn't see
these: they're only added with the button. After finishing a Room Layout scan, **Save to Account**
sends its complete edited USDZ, raw PLY, RoomPlan JSON and edit metadata through the Mac gateway
to the app owner's `RoomTwin` Google Drive folder. Users never sign into Google or choose a folder.
Supabase stores only the per-user room record and owner-Drive paths.

Accounts live on Supabase, which the app calls directly. Room files use the object-server Mac as
the owner-Drive gateway. Set Supabase up once:

1. Make a free Supabase project. Under **Authentication › Sign In / Providers › Email**, turn
   **Confirm email** off. Usernames become placeholder addresses (`name@users.roomtwin.app`)
   that never get mail.
2. Put `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_DB_URL` (Connect › URI) in `.env.local`.
3. Run `python3 Accounts/setup_supabase.py`. It creates the `objects` and `room_layouts` tables and
   their private file buckets (`Accounts/schema.sql`), and writes `RoomTwin/supabase.json` for the
   app. Then it checks both upload/save/list/delete paths with a throwaway user. Rebuild the app
   afterwards.

The anon key in the app can only do what row-level security allows: each user reads, adds and
deletes their own rows, and files under a folder named after their user ID. The database URL is
only used by the setup script and never goes into the app.

Authorize the owner's Drive once on the Mac with
`rclone config create roomtwin-owner drive scope drive config_is_local true`, then keep
`bash ObjectServer/start.sh` running during the demo. The server stores rooms under
`Google Drive/RoomTwin/Users/<Supabase user ID>/Rooms/<room ID>/`, with library models and
thumbnails in `Google Drive/RoomTwin/Users/<Supabase user ID>/Objects/<object ID>/`.
Older room paths remain readable. Google credentials remain in rclone's
Mac configuration and are never copied to the app.

Room Export and Save use the same USDZ writer. The USDZ packages the scene's editable
furniture, SAM replacements, added models, walls/floor materials and enclosure together;
image materials are resolved into temporary PNGs before packaging so textures travel with
the model. The PLY sidecar is the original coloured scan archive, not a textured scene file.
Edit metadata accompanies saved rooms to restore transforms, materials and lighting.

## Furnish by voice

In the room preview, tap **Talk** and say one command. Talk is one-shot: the agent performs that
single request, answers with one concise result such as **“Done — I moved the table to the left.”**,
and disconnects as soon as the reply finishes. It never waits for a second command in the same paid
voice session.

- **"Hey, can you add a chair"** stands one on the floor where the middle of the screen points,
  facing you.
- **"Add a table by the wall"** backs it up to the wall you're looking at, or the nearest one,
  facing into the room. **"…facing the wall"** turns it round with room to sit, like a chair at a
  desk.
- **"Add a lamp and a table by the wall facing out"**: the biggest piece goes first, and the
  others go beside it or on it. **"Put a plant on the table"** sets it on top.
- **"Make the walls red brick"** textures every wall; **"this wall"** only the one in view.
  **"Put the walls back"** undoes it.
- **"Make the floor oak"** changes only the ground; **"make the sofa red velvet"** changes an
  added object's material; **"make the table 80 centimetres tall"** resizes it without allowing
  it to overlap another object.
- **"Add a ceiling light"** hangs it from the ceiling. Lamps and light fixtures emit light, and
  requests such as **"make the room warmer and brighter"** tune the whole lighting rig.
- **"Add a floating bookshelf on the wall"** mounts one above the floor instead of standing it on
  the ground; the wall placement checks its full width and height before accepting the spot.
- RoomPlan furniture is editable too: **"move chair 2 left"**, **"make the scanned table walnut"**,
  **"replace the sofa with a leather sofa"**, resize it, or remove it. Detected furniture is kept
  upright even when RoomPlan reports a small pitch or roll beside a wall.
- **"Enclose the room with a ceiling and close the open wall"** adds an exportable ceiling and
  fills missing boundary walls; either part can be removed again by voice.
- **"Remove the lamp"** takes it away. With no name, the latest editable piece goes.

Everything stands upright on the floor, and each spot is checked first. If a wall, table or
earlier piece is in the way, it moves to the nearest clear floor you can see. If there's no room,
the agent says so.

You can edit without voice as well. Tap any detected RoomPlan object or added model in Orbit/Walk
to select it, then use the move, rotate, smaller, larger and delete controls. **Add** opens the
signed-in user's saved object library.

For hand editing, make a **Detailed Mesh** scan, add at least one editable object, open **View › AR
Edit**, and enable **Hand Tracking**. Vision detects one hand entirely on-device at up to 15 FPS;
the render/camera loop remains 60 FPS. Pinch detection is normalized to palm size, confirmed across
two frames, and uses a wider release threshold. Furniture moves on a stable floor, wall, or
camera-facing plane with the same collision checks as other edits. ARKit plane raycasts validate
the initial anchor; LiDAR depth is not treated as fingertip depth. A lost hand is tolerated briefly,
then the last valid placement is released safely.

**Where the models come from.** Poly Haven first: its models are CC0, true to scale and all
face the same way. The app downloads them at 1k (about a megabyte, a second or two). When Poly
Haven has nothing close in name and size (it has no floor lamp, for one), the model comes from
Sketchfab. It's scaled to the height the agent expects, and its credit (name, author, licence)
shows under the buttons, as CC BY requires. Wall textures are Poly Haven's, tiled at their real
size. The preview says "Powered by Poly Haven", as its API terms ask.

**How it works.** An ElevenLabs agent listens and answers; Claude Haiku 4.5 decides what to do.
Its tools run in the app: adding/removing/resizing objects, changing wall/floor/object materials,
and tuning lighting. The app finds the walls itself, as large
vertical planes along the room's two main directions, so it works on mesh scans and RoomPlan rooms
alike. A mesh scan needs its walls actually scanned, though: one that's mostly furniture has few
walls to stand things against.

Preview edits remain in place after closing and reopening View. USDZ export contains the edited
walls and floor, added objects, their material and size changes, and the room lights; PLY remains
the raw vertex-colour scan because that format has no SceneKit materials or light nodes.

Set it up once on the Mac:

1. Make an ElevenLabs API key with **ElevenAgents: Write** and **Voices: Read**, and put it in
   `.env.local` as `ELEVENLABS_API_KEY=...`.
2. For Sketchfab, add `SKETCHFAB_API_TOKEN=...` (Sketchfab › Settings › Password & API).
   Downloads count as your account's.
3. With the phone connected and RoomTwin opened once, run `python3 Voice/setup_agent.py`. It
   creates or updates the agent and its tools and saves their IDs in `.env.local`. Then it copies
   the agent ID, and the Sketchfab token if there is one, to the phone. The app moves the token
   into its Keychain and deletes the copy.

The phone never gets the ElevenLabs key. The agent is public, so a leaked ID could start
conversations; calls now end after 12 seconds of server-side silence, the app hangs up immediately
after its one short answer, and hard limits of 60 seconds each, 25 a day and one at a time cap cost.

## Room Layout: RoomPlan

Room Layout uses Apple's RoomPlan instead of our mesh. Apple's view draws white outlines on the
walls, doors, windows and furniture as it finds them, with its own tips ("Move further away"). Walk
round the room, then tap **Done**. RoomPlan tidies the room and shows it, and the bar at the top
counts what it found. **Cancel** drops the scan.

The finished room is built from RoomPlan's boxes: flat walls with doors, windows and openings cut
out, doors and windows as panels, and the floor. Furniture RoomPlan labels as a chair, sofa or table
gets the matching model from `RoomTwin/Library`, stretched to the size RoomPlan measured. Sloped or
gabled wall tops and their top caps are retained in Orbit and Walk rather than flattened. Anything
else is a coloured box. Then the same buttons as a mesh scan:

- **View** opens the room in the same 3D preview, with Orbit, Walk and Talk. Camera-based AR Edit is
  currently limited to Detailed Mesh scans because a finished RoomPlan capture no longer shares
  its AR world origin with the main scanner session; touch editing remains available here.
- **Export** shares three files from `Documents/RoomPlan-<time>/`: the room as `.usdz` and `.ply`
  (as shown in View), and RoomPlan's `.json`. The JSON lists every wall, door, window and object
  with its category, size and position.
- **Save to Account** stores the edited USDZ plus the raw PLY and RoomPlan JSON in the current
  user's private cloud library.
- **New Scan** goes back to Start Scan.

Room Layout scans don't record keyframes, so the Colab furniture pipeline doesn't run on them.

## Hybrid scan

Hybrid runs the existing coloured Detailed Mesh reconstruction and RoomPlan semantics from one
shared `ARSession` (iOS 17 or later). The Metal view and camera request 30 FPS; fusion is capped at
30 updates per second, falls to 15 at a serious thermal state, and falls to 8 at a critical state.
The scan overlay reports measured render/fusion FPS, GPU time, process memory, thermal state and
triangle count. RoomPlan's live walls, openings and object boxes are drawn by the same Metal render
pass and projected from the same AR frame as the detailed mesh. The white guidance therefore tracks
the camera at 30 FPS instead of lagging behind in a separate SwiftUI overlay, and both scan results
remain visible without a second camera view. Detailed Mesh and Room Layout keep their original
performance and behaviour.

Tap **Finish** to stop fusion and ask `RoomBuilder` for RoomPlan's final room without pausing the
shared AR session. RoomPlan then supplies the authoritative clean walls, floor, openings and
independent furniture. Large semantic triangles are subdivided to a roughly 12 cm grid, and colours
from nearby, similarly oriented Detailed Mesh vertices are sampled onto that grid. Areas hidden by
detected furniture retain the flat RoomPlan surface colour, so moving a table reveals a complete
floor or wall rather than a hole in the fused scan.

RoomPlan furniture uses the same Orbit/Walk selection, gizmo, voice, hand tracking, undo/redo,
material, replace and delete code as other editable furniture. Hybrid export includes the
edited USDZ, raw PLY and a `.roomplan.json` semantic sidecar. If RoomPlan fails or the phone gets
too hot for it, the Detailed Mesh result remains available.

Hybrid deliberately does not claim to recover exact furniture triangles from the fused LiDAR mesh:
RoomPlan doesn't provide such a mask. It prioritizes stable editable topology and transfers the
captured appearance where the two reconstructions agree spatially.

### Clean scan

Clean combines Hybrid's authoritative RoomPlan geometry with SAM Furniture's manual replacement
workflow. Walls, floors, openings and unphotographed objects come from RoomPlan; the LiDAR mesh is
used only as a colour/texture sample source and its irregular geometry is not included in the final
Clean preview. Photographed furniture is replaced before the result is revealed. Structural guides
remain white, while furniture follows the red / yellow-at-20% / green capture states described
below. Clean exports the raw detailed PLY as a source sidecar, the RoomPlan JSON, the final edited
USDZ, and a SAM manifest identifying the clean output mode.

### SAM Furniture scan

SAM Furniture also captures Detailed Mesh and RoomPlan from one shared session, but it deliberately
uses them differently. The coloured LiDAR mesh remains the authoritative room, including the wall,
floor and irregular surface detail. RoomPlan is used only as the list and oriented bounds of
furniture that may be replaced.

While scanning, an item becomes eligible only after its RoomPlan box has remained stable and at
least 20% of that box is inside the phone viewport. All detected furniture, including low-confidence
and small items, can be photographed. Furniture boxes are red before an optional manual photo,
yellow once they meet the 20% rule, and green after a photo is safely written. The user
must tap **Photo** while a box is yellow; RoomTwin rejects the shot otherwise. It saves exactly one
colour/depth frame for the best visible yellow item and never photographs furniture automatically.
The live status shows `captured / detected`. Each newly detected furniture item increases
the session total; temporarily losing a live box does not decrease it. Reidentifying the
same box does not add another checklist entry, and separate neighboring items count separately.
Photos are optional: **Finish** also works with
zero photos and does not contact SAM in that case. Unphotographed items keep their default
RoomPlan shapes in Clean mode, or their scanned geometry in SAM Furniture mode.

After Finish, RoomTwin hides the unfinished detailed scan and completes replacement before opening
the result. The progress card names each real stage: finalizing RoomPlan, preparing the detailed
mesh, connecting to the server, uploading the item's one photo, finding the object inside its
projected RoomPlan box, building it with SAM 3D Objects, downloading it, repairing the newly exposed
surface, and building the editable preview. If the server is unavailable, no partial result is
shown; the user can start the server and tap **Retry** without rescanning.

Export remains available for archiving and includes a `.sam.json` marker beside the raw `.ply` and
`.roomplan.json`. With that marker present, SAM 3 only asks for categories RoomPlan actually detected. Every image mask must
overlap the matching projected RoomPlan box, and every lifted scan vertex must remain inside that
specific object's 3D box. This prevents an unrelated object from being added and keeps two nearby
pieces of the same category independent. A detected object with no sufficiently clear photo or
mesh evidence is left unchanged.

After SAM 3D Objects successfully generates a replacement, only that object's scanned triangles are
removed. A small RoomPlan floor or wall patch is added immediately behind the removed object, using
colour sampled from the surrounding detailed mesh. RoomPlan does not flatten or replace the rest of
the room. This gives the useful "flat surface behind a moved table" behaviour while retaining the
detailed scan everywhere else.

## Objects: Photo and Walk Around

The switch at the top has two ways to turn one object into a 3D model. Either way, when the model is
ready the picture greys out and the model pops out of it and spins. **View in AR** places it in the
room at its real size, and **swiping the model up** sends it to your Mac (see RoomTwin Viewer below).
Models are saved in **Files › RoomTwin › Objects**.

**Walk Around** runs entirely on the phone, with Apple's Object Capture. Point at the object, tap
**Continue**, fit the box around it, tap **Start Capture** and walk slowly all the way round while it
takes photos. Then tap **Finish**, or **Another Pass** to go round again higher or lower. The phone
builds a textured model in a few minutes. Shiny, see-through and very thin objects don't work well.
The photos stay in the capture's folder, so a Mac can rebuild them at higher detail.

**Photo** needs only one photo. Take a photo and tap one or more visible parts of the same object:
every blue numbered point refines a single SAM 3 mask. Use **Clear** to start the selection again without
retaking or re-uploading the photo. SAM 3
masks it, and **Large / Medium / Small** pick between its three guesses (a whole chair, its seat, …).
Tap **Generate 3D** and SAM 3D Objects builds the full object, back included, in about 30 seconds,
guessing the sides it can't see. The LiDAR depth sets its real size.

For Photo mode, start the object server on your Mac first, with the phone connected and on the
same Wi-Fi as the Mac:

```sh
bash ObjectServer/start.sh
```

It starts `server.py` (SAM 3) and `generator.py` (SAM 3D Objects) on the Colab session `roomtwin`,
set up with `Furniture/colab_setup.sh`, and tunnels them to the Mac's Wi-Fi address over
`colab ssh`. Then it sends the address and a fresh token to the app. Keep it running while you use
Photo mode. Ctrl-C stops both models and frees the GPU for the room pipeline. If the phone isn't
connected, the script prints the address and token, and you type them in after tapping the server
button in Photo mode.

For an automatic hosted fallback, add `FALKEY=...` to `.env.local` and install Assimp once with
`brew install assimp`. `start.sh` then also runs a small authenticated gateway on the Mac. RoomTwin
prefers the self-hosted Colab models; if that server is unavailable, a request fails, or generation
times out, it retries the same manually captured image with `fal-ai/sam-3/3d-objects`. The fallback
uses the RoomPlan box as fal's box prompt, fits the returned mesh back into that box, and keeps the
original RoomPlan direction. The fal key remains on the Mac and is never copied into the app.

### RoomTwin Viewer on the Mac

A menu-bar app that waits for models sent from the phone. It covers the screen with an invisible
layer that lets clicks through. When a model arrives, the screen greys out and the model flies up
from the bottom edge, lands and spins. Click anywhere or press Esc to put it away. Received models
are saved in `~/Downloads/RoomTwin`, and the menu-bar icon can show the last one again.

```sh
xcodebuild -project RoomTwin.xcodeproj -scheme RoomTwinViewer -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
open build/DerivedData/Build/Products/Release/RoomTwinViewer.app
```

The phone and the Mac find each other directly over Wi-Fi or Bluetooth (Multipeer Connectivity),
so there's no address to set up. Both just need to be nearby with Wi-Fi or Bluetooth on.

## Replace scanned furniture with SAM 3D models

While you scan, the app saves keyframes: about two photos a second, each with its LiDAR depth,
confidence, camera pose and intrinsics. They go into the scan's folder in Documents, next to the
exports. After a scan and an Export, with the phone connected, run:

```sh
bash Furniture/run_on_colab.sh            # newest scan; or pass its RoomTwin-<date> folder name
```

The script copies the scan off the phone and runs four steps on the Colab GPU. Then it writes
`scans/<scan>/twin/room_twin.usdz`, which opens in Quick Look.

1. `segment.py`: SAM 3 masks furniture in every keyframe from text prompts (chair, sofa, table, …).
   In a SAM Furniture scan, prompts and detections are restricted to the exported RoomPlan targets.
2. `lift.py`: each keyframe votes on which scan vertices belong to which piece. Floor-height
   vertices never count, since masks spill onto the floor. The step also picks each piece's most
   complete, unclipped view.
3. `generate.py`: SAM 3D Objects builds each piece from that view. A metric point map from the
   LiDAR depth sets its size, and the predicted pose moves it into the room.
4. `assemble.py`: fits each model to its scanned surface with ICP, rigid unless the scan covers most
   of the model, and drops it onto the floor. It removes the scanned piece and writes
   `room_twin.ply` along with the fitted objects and `placement.json`. For SAM Furniture exports it
   also fills only the local RoomPlan floor/wall area hidden by each successfully replaced target.

`debug/` shows the photo each model came from. Rerun single steps on the VM with
`run_pipeline.sh SCAN generate assemble`, and use `assemble.py --keep 3` to leave object 3 as
scanned. `python3 Furniture/synthetic_test.py` checks the original steps 2 and 4 on a synthetic
room, with no GPU. `python3 Furniture/sam_mode_test.py` checks target restriction and local surface
repair for the SAM Furniture mode.

SAM 3D Objects needs Linux and an NVIDIA GPU with at least 32 GB, so this runs on a Colab A100.
`Furniture/colab_setup.sh` prepares a fresh VM in about 20 minutes and needs Hugging Face access
to `facebook/sam3` and `facebook/sam-3d-objects`. Object mode shares the same VM, but stop its
server first, because both pipelines together don't fit in 40 GB.

## Check the algorithm on a Mac

`ReconCheck` runs the same reconstruction code on your Mac's GPU against a synthetic room. It
verifies the data-structure invariants (one vertex per edge, exact reference counts, no leaks,
balanced free lists, manifold and consistently wound mesh) and how close the vertices are to the
true surfaces.

```sh
xcodebuild -project RoomTwin.xcodeproj -scheme ReconCheck -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
./build/DerivedData/Build/Products/Release/ReconCheck /tmp/roomtwin-check
```

It also writes `synthetic-room.ply`, `synthetic-room.usdz` and two PNG renders to the output folder.

To turn PLY scans into Quick Look–ready USDZ, which writes `scan.usdz` next to each file:

```sh
./build/DerivedData/Build/Products/Release/ReconCheck usdz scans/*.ply
```

Quick Look ignores per-vertex colors, so the USDZ export bakes them into a texture: one 2×2-texel cell
per triangle, laid out in Z-order so mipmapping only blends nearby triangles. That needs 3 vertices per
triangle, which makes the USDZ about 5× larger than the PLY.

## Layout

| Folder | Contents |
|---|---|
| `Reconstruction/` | Shared by both targets. Metal kernels (`Reconstruction.metal`), mesh shaders, the Swift host (`Reconstructor.swift`), PLY and USDZ export, PLY reading. |
| `RoomTwin/` | The iOS app: ARKit session, camera background, SwiftUI controls, login and accounts, the scan preview with its wall finder and furniture placement, the voice agent, Poly Haven and Sketchfab downloads, Photo and Walk Around modes. `Library/` holds the SAM 3D furniture RoomPlan rooms use. |
| `ReconCheck/` | The macOS test tool. |
| `Furniture/` | The furniture-replacement pipeline (SAM 3 + SAM 3D Objects on Colab) and its Mac driver script. |
| `Voice/` | Sets up the ElevenLabs voice agent (`setup_agent.py`) and builds the furniture library from a twin (`make_library.py`). |
| `Accounts/` | The Supabase schema (`schema.sql`) and the script that applies it and points the app at the project (`setup_supabase.py`). |
| `ObjectServer/` | Photo mode's server on the Colab VM (`server.py`, `generator.py`) and the Mac script that starts it. |
| `RoomTwinViewer/` | The Mac menu-bar app that receives models from the phone. |
| `Shared/` | Used by the app and the Viewer: the spinning model view and the transfer's service name. |
| `tools/gen_mc_tables.py` | Generates `Reconstruction/MarchingCubesTables.h`. |

Tunables are in `ReconstructionSettings` (`Reconstruction/Reconstructor.swift`). The defaults are
2 cm voxels, 3.5 m max depth, high-confidence LiDAR pixels only, and about 450 MB of GPU memory.

## Differences from the paper

- **No per-vertex locks.** The paper locks each vertex while it's allocated. Here the first cube to
  claim an edge allocates the vertex with a compare-and-swap, and every other cube reads it in the
  next dispatch. This matters because Metal doesn't guarantee spin locks make progress.
- **Hamming-distance refinement is off by default.** It's implemented
  (`refineThresholdInVoxels`, try 0.3), but neighbouring cubes snap independently. When a surface
  lies within the threshold of a voxel plane, cubes on both sides snap, leaving overlapping sheets
  and cracks. In `ReconCheck` it doubles the open edges and doesn't reduce topology changes. With
  walls aligned exactly to the grid, it cuts changes by 30% but opens 36× more edges.
- **Normals are computed in the fragment shader**, from screen-space derivatives, instead of being
  stored per vertex.
