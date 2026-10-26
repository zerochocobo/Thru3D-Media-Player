# Provider icon sources and modifications

Prepared 2026-10-26 for identifying connected services in Thru3D. These are
third-party product marks; the WebDAV pictogram is original to this project.
The retained `.svg` files are source material, not runtime downloads.

| Mark | Retained source | Upstream source / credit |
| --- | --- | --- |
| 115 | `115.svg` | [115 official website](https://115.com/), [official SVG](https://w.115.com/m_r/web/static/images/icon_logo_cloud_darkblue.svg) |
| Emby | `emby.svg` | [Simple Icons / Emby](https://github.com/simple-icons/simple-icons/blob/develop/icons/emby.svg), CC0-1.0 |
| Jellyfin | `jellyfin.svg` | [Jellyfin UX / flat icon](https://github.com/jellyfin/jellyfin-ux/blob/master/logos/SVG/jellyfin-icon--flat-on-dark.svg), CC BY-SA 4.0 |
| Plex | `plex.svg` | [selfh.st icons](https://github.com/selfhst/icons/blob/main/svg/plex-dark.svg), CC BY 4.0 |
| Stash | `stash.svg` | [Stash project](https://github.com/stashapp/stash/blob/develop/ui/v2.5/public/stash_icon.svg), project AGPL-3.0 |
| XBVR | `xbvr-original.png`, `xbvr.svg` | [XBVR project icon](https://github.com/xbapps/xbvr/blob/master/ui/public/icons/xbvr-512.png); vector reconstruction of its white wordmark |
| Baidu Netdisk | `baidu.svg` | [Arcticons Team](https://github.com/Arcticons-Team/Arcticons/blob/main/icons/white/baidu_netdisk.svg), GPL-3.0 |
| Aliyun Drive | `aliyun.svg` | [Arcticons Team](https://github.com/Arcticons-Team/Arcticons/blob/main/icons/white/alibaba_cloud_disk.svg), GPL-3.0 |
| Quark Netdisk | `quark.svg` | [Arcticons Team](https://github.com/Arcticons-Team/Arcticons/blob/main/newicons/quark_cloud_drive.svg), GPL-3.0 |
| OneDrive | `onedrive.svg` | [selfh.st icons](https://github.com/selfhst/icons/blob/main/svg/microsoft-onedrive-2018-dark.svg), CC BY 4.0 |
| WebDAV | `webdav.svg` | Original globe / bidirectional transfer pictogram, project GPL-3.0 |

`tools/Prepare-ProviderIcons.py` reproducibly creates the runtime vectors in
`app/godot/assets/provider-icons/`. Changes: remove application tile backgrounds
and editor/filter metadata, convert visible geometry to white, increase the
three line-art marks' stroke width, and centre/scale each mark into a common
128 x 128 transparent canvas. Plex uses the source's chevron cutout as a positive
mark. XBVR's wordmark is reconstructed as paths, without its magenta tile.
The existing ray-menu renderer supplies a neutral gray/white foreground and
mipmaps; no raster matte or remote request is used at runtime.

Upstream license texts are retained in the `LICENSE-*.txt` files in this directory.
Packaged attribution is in
`third_party/player-licenses/provider-icons.txt`. Product names and marks remain
associated with their respective owners; collection licenses do not transfer
trademark rights or imply endorsement.
