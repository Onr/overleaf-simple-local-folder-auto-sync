# Overleaf Auto Sync (Gum CLI)

A small, interactive CLI tool (built with **Gum** + **Git**) to keep a local folder and an Overleaf project in sync.

Use VS Code (or any editor) to write your LaTeX locally, while this script:

* Clones or connects to your Overleaf Git project
* Auto-commits local changes
* Pulls remote changes from Overleaf
* Pushes everything back on a configurable interval

All behind a friendly UI.

<img width="229" height="183" alt="image" src="https://github.com/user-attachments/assets/8e3ef6fc-2140-423c-b649-f9f0153eca3c" />

<img width="1845" height="773" alt="image" src="https://github.com/user-attachments/assets/1c19151e-4c95-455d-9672-7e9e46b486a9" />



---

## Requirements

* **bash**
* **git**
* **[Gum](https://github.com/charmbracelet/gum)** (for the fancy TUI prompts)


---

## Installation

1. Copy the script into your repo (e.g., as `overleaf_autosync.sh`), or clone this repo.


2. Install **[Gum](https://github.com/charmbracelet/gum)**.

---

## Getting the Overleaf Git URL

In Overleaf:

1. Open your project
2. Go to **Menu → Git**
3. Copy the Git URL (looks like `https://git@git.overleaf.com/<project-id>`)

You can paste that directly into the script when prompted.

---

## Usage

### 1. Start the tool

From the directory where the script lives:

```bash
./overleaf_autoupdate.sh
```

The script will start an interactive Gum-based setup.
Just follow the on-screen instructions.

---

## Tips & Caveats

* For big binary files or very large projects, frequent auto-commits + pushes may be problematic.




---

