# ItemWarehouse

**ItemWarehouse** is a light, efficient inventory tracking add-on designed for **World of Warcraft 3.3.5a** (Wrath of the Lich King). It tracks scanned inventory sources across your characters and guild banks using non-destructive delta updates, offering quick item inspection and multi-format data exports.

---

## Key Features

* **Automatic Inventory & Personal Bank Scanning:** Automatically performs non-destructive scans of your bags on inventory updates and scans your personal bank whenever opened.
* **Guild Bank Tab Scanning:** Integrates a dedicated "Scan Tab" button directly onto the Guild Bank frame to record item quantities and stack sizes for visible tabs.
* **Non-Destructive Data Merging:** Updates scanned items without dropping existing entries, logging delta changes and total quantities per scanned source.
* **Multi-Format Export Engine:** Modal export interface that generates inventory lists in Plain Text, Discord Markdown bullet points, or Spreadsheet (Tab-Delimited) formats.
* **Built-in Debug Logging Engine:** Maintains a rolling debug log with real-time memory usage tracking, viewer UI, and clearing tools.
* **Chat Link Integration:** Shift-click or right-click items in the viewer UI to insert standard item hyperlinks directly into active chat edit boxes.
* **Minimap & Command Controls:** Draggable minimap button (Fish Feast icon) and slash commands (`/iw`, `/itemwarehouse`) to open the dashboard, config panel, or debug log.

---

## Installation

### Method 1: Installing via GitHub "Code" ZIP Download (Recommended)

1. Navigate to the main page of the **ItemWarehouse** GitHub repository.
2. Click the green **`Code`** button located near the top right of the repository view.
3. Select **`Download ZIP`** from the dropdown menu.
4. Save and extract the `.zip` archive.
5. Open the extracted folder. Inside, you will find a pre-formatted `ItemWarehouse` folder.
6. Drag or copy the `ItemWarehouse` folder directly into your World of Warcraft 3.3.5 AddOns directory:
   `C:\Program Files (x86)\World of Warcraft\Interface\AddOns\`
7. Launch or restart World of Warcraft 3.3.5. Ensure `ItemWarehouse` is enabled in your **AddOns** list on the Character Selection screen.

---

### Method 2: Installing via Direct Repository Clone (Git CLI)

If you use Git for version control, clone the repository directly into your WoW client installation directory.

1. Open your terminal or command prompt.
2. Navigate to your World of Warcraft `AddOns` directory:
   `cd "C:\Program Files (x86)\World of Warcraft\Interface\AddOns"`
3. Run `git clone` targeting the explicit destination folder name **`ItemWarehouse`**:
   `git clone https://github.com/\<your-username\>/ItemWarehouse.git ItemWarehouse`
4. Launch World of Warcraft 3.3.5 and log in.

---

## Author & License

* **Author:** Copper
* **Client Compatibility:** World of Warcraft 3.3.5a (Build 12340 / DirectX 9)
* **License:** GPL 3.0
