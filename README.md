# ebay-auto-listing-assistant

Automate eBay listing creation from folders of product images—with AI-powered product info, concise descriptions, and optional multimodal (image+text) condition-aware descriptions.

**Tested with the latest OpenAI models:**  
- `gpt-4.1-2025-04-14`
- `gpt-4o-2024-08-06` (including vision/multimodal)

---

## Features

- **Batch compresses images:** Uses ImageMagick to reduce JPEG size and strip EXIF.
- **AI-powered product information extraction:** Fills table fields using GPT-4o or GPT-4.1, based on folder names.
- **Succinct AI-written eBay descriptions:** Clean, to-the-point, ready for copy/paste or bulk upload.
- **Optional multimodal finishing:** Running with flag -i sends products’ images to GPT-4o, to get condition-verified eBay descriptions (text + image context).
- **Generates eBay uploadable CSVs:** All fields, including info and generated descriptions aggregated in a csv to allow customation for easy integration with eBay’s bulk listing tools.
- **Easy configuration:** Paths, models, and endpoints in `.env` for simple swapping models.
- **Verbose logging:** See progress step by step with `-v`.
- **Ubuntu Dependency Auto-Install:** Attempts to install `jq`, `magick`, `curl`, and `file` on first run (Ubuntu+Debian, via `apt`) if they're missing.

---

## Requirements

- Bash
- [ImageMagick v7+](https://imagemagick.org/) (`magick`)
- [`jq`](https://stedolan.github.io/jq/)
- [`curl`](https://curl.se/)
- OpenAI API key in .env:
    - For search/info: any model supporting openai query structure. Remove `temperature` option if not supported by the model 
    - For image/vision/multimodal: ensure the model supports image processing and the API key you provide has image features enabled.

**Dependencies will be auto-installed on first run (Ubuntu/Debian `apt`) if missing.**

---

## Setup & Instructions

### 1. Clone & configure

```sh
git clone https://github.com/yourusername/ebay-auto-listing-assistant.git
cd ebay-auto-listing-assistant
cp .env_example .env    # edit .env per your setup & API keys
```
Edit .env with your OpenAI API key, models, and the actual path to your product folders.
### 2. Organize your product folders

Each subfolder should contain only images for that product. Preferred naming:

Product name plus condition.

```
/your/ebay_folders/
  |- Nintendo DS Lite Used/
  |- Lego Set 75257 Good/
  |- iPhone 14 Plus Mint/
```
Images should be: jpg or jpeg

### 3. Run the tool

Default (quiet)
This issues two calls to openai per product, to first gather product info in a structured way and another to generate a brief description based on condition indicated in folder name/title:

```sh
./ebay_auto2.sh
```
Verbose mode:

```sh
./ebay_auto2.sh -v
```

With additional multimodal prompt to update item description with condition from images (text+images):

```sh
./ebay_auto2.sh -i
```
With both verbose and multimodal:

sh

./ebay_auto2.sh -v -i

Or set MULTIMODAL_ALWAYS=1 in .env to apply image+text flow to every product by default.
Outputs

    upload/ — compressed, metadata-stripped images (new subfolder).
    [productname]-info.csv — product information from LLM search.
    [productname]-desc.txt — standard AI eBay description.
    [productname]-desc-image.txt — optional condition-aware, image-informed description (when -i/--imagequery is used).
    ebay_bulk_upload.csv — all info/descriptions merged, ready for eBay’s bulk CSV import.

CSV fields will contain all description text, sanitized for newlines/quotes.

---

## Troubleshooting

    - If you see "OpenAI API error: See log." in files, check your console/platform logs

    - Remove temperature parameter option if not supported by the model 

    - If a dependency is missing, the script will attempt to install it using sudo apt-get install (Ubuntu/Debian only).

    - If a folder’s images do not process, check that files are named .jpg/.jpeg and readable.

License

This project is licensed under the terms of the GNU General Public License v3.0 (GPL-3.0).

See LICENSE for complete terms.
Contributing

PRs, issues, and improvements are welcome!

Tested with OpenAI models:

    gpt-4.1-2025-04-14
    gpt-4o-2024-08-06

