# LPH Trading Tools Repository

Official file and metadata repository for the Limitless PH Member Trading Tools portal ([https://limitlessphtraining.com/trading-tools](https://limitlessphtraining.com/trading-tools)).

---

## 🚀 How to Add or Update Tools on Your Website

Your website automatically reads the `tools.json` file in this repository.

### 1. Updating an Existing Tool
1. If you have an updated `.zip` file, go to **Releases** → **Create a new release** (e.g. `v1.1.0`), and attach your new `.zip` file.
2. Edit `tools.json` in this repository:
   - Update `"version"` (e.g. `"v2.5"`)
   - Update `"fileSize"` (e.g. `"ZIP • 15.2 MB"`)
   - Update `"updated"` (e.g. `"Aug 2026"`)
   - Keep `"downloadUrl"` as the branded page URL using that tool's stable ID.
   - Update `"fileUrl"` to your new release asset link.
3. Commit your changes. **Your website updates automatically within minutes!**

### 2. Adding a New Tool
Add a new object inside `tools.json`:

```json
{
  "id": "new-indicator-name",
  "name": "LPH New Indicator Name",
  "category": "indicators",
  "categoryLabel": "Indicators",
  "tagColor": "cyan",
  "version": "v1.0",
  "fileSize": "ZIP • 3.5 MB",
  "updated": "Aug 2026",
  "downloadUrl": "https://limitlessph03.github.io/lph-trading-tools/download.html?tool=new-indicator-name",
  "fileUrl": "https://github.com/limitlessph03/lph-trading-tools/releases/download/v1.0.0/Your_File.zip",
  "description": "Brief description of the tool."
}
```

### 3. Categories & Colors
* **Categories**: `ea`, `indicators`, `templates`, `suite`, `utilities`
* **Tag Colors**: `gold`, `cyan`, `blue`, `green`, `red`, `purple`

The GoDaddy portal must use `downloadUrl`. The branded page resolves the selected registry item and exposes `fileUrl` only after a manual second click; it never auto-redirects or accepts an arbitrary URL parameter.
