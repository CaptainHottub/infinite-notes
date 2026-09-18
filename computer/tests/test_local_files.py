from pathlib import Path
import pytest
import local_files


def test_export_destination_survives_reload_and_is_not_reused_for_another_notebook(tmp_path):
    local_files.set_origin(tmp_path, 'first', tmp_path)
    assert local_files.get_origin(tmp_path, 'first') == tmp_path
    assert local_files.get_origin(tmp_path, 'second') is None
    local_files.clear_origin(tmp_path)
    assert local_files.get_origin(tmp_path, 'first') is None


def test_failed_export_leaves_existing_files_and_no_temporary_file(tmp_path):
    existing = tmp_path / 'notes.pdf'
    existing.write_bytes(b'original')
    with pytest.raises(OSError):
        local_files.save_export(tmp_path / 'missing.pdf', tmp_path, 'notes.pdf')
    assert existing.read_bytes() == b'original'
    assert sorted(path.name for path in tmp_path.iterdir()) == ['notes.pdf']


def test_missing_destination_does_not_silently_create_a_new_folder(tmp_path):
    source = tmp_path / 'source'
    source.write_bytes(b'export')
    with pytest.raises(OSError):
        local_files.save_export(source, tmp_path / 'missing', 'notes.pdf')
    assert not (tmp_path / 'missing').exists()


def test_export_to_filesystem_without_hardlinks_preserves_existing_files(monkeypatch, tmp_path):
    import errno
    source = tmp_path / 'source'
    source.write_bytes(b'export')
    (tmp_path / 'notes.pdf').write_bytes(b'original')
    def unsupported(*args):
        raise OSError(errno.EOPNOTSUPP, 'hard links unsupported')
    monkeypatch.setattr(local_files.os, 'link', unsupported)
    destination = local_files.save_export(source, tmp_path, 'notes.pdf')
    assert destination.name == 'notes (1).pdf'
    assert destination.read_bytes() == b'export'
    assert (tmp_path / 'notes.pdf').read_bytes() == b'original'
    assert not list(tmp_path.glob('.infinite-notes-export-*'))


def test_corrupt_destination_record_is_preserved_and_can_be_reselected(tmp_path):
    record = tmp_path / 'export-origin.json'
    record.write_text('broken json')
    assert local_files.get_origin(tmp_path, 'doc') is None
    assert record.read_text() == 'broken json'
    local_files.set_origin(tmp_path, 'doc', tmp_path)
    assert local_files.get_origin(tmp_path, 'doc') == tmp_path
