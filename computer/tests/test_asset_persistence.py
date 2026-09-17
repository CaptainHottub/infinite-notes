from asset_persistence import begin_transition, install_asset_set, recover_transition


def make_assets(root, label):
    root.mkdir(parents=True, exist_ok=True)
    (root / "pdf_pages").mkdir()
    (root / "current.pdf").write_bytes(label.encode())
    (root / "pdf_pages" / "page-0001.svg").write_text(f"<svg>{label}</svg>")


def test_interrupted_asset_install_restores_old_generation_if_database_did_not_commit(tmp_path):
    live = tmp_path / "live"
    prepared = tmp_path / "prepared"
    make_assets(live, "old")
    make_assets(prepared, "new")
    transition = begin_transition(live, live / "current.pdf", live / "pdf_pages", prepared, 8)
    install_asset_set(transition / "new", live / "current.pdf", live / "pdf_pages")
    assert (live / "current.pdf").read_bytes() == b"new"

    assert recover_transition(live, live / "current.pdf", live / "pdf_pages", 7)
    assert (live / "current.pdf").read_bytes() == b"old"
    assert (live / "pdf_pages" / "page-0001.svg").read_text() == "<svg>old</svg>"
    assert not transition.exists()


def test_interrupted_asset_install_finishes_new_generation_after_commit(tmp_path):
    live = tmp_path / "live"
    prepared = tmp_path / "prepared"
    make_assets(live, "old")
    make_assets(prepared, "new")
    transition = begin_transition(live, live / "current.pdf", live / "pdf_pages", prepared, 8)
    (live / "current.pdf").unlink()

    assert recover_transition(live, live / "current.pdf", live / "pdf_pages", 8)
    assert (live / "current.pdf").read_bytes() == b"new"
    assert (live / "pdf_pages" / "page-0001.svg").read_text() == "<svg>new</svg>"
    assert not transition.exists()
