#!/usr/bin/env python3
"""Document identity and page-boundary regression checks."""
import pathlib
import runpy
import tempfile
import unittest

validate = runpy.run_path(str(pathlib.Path(__file__).with_name('omabib-quick-note')))['validate_document']


class DocumentContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.pdf = pathlib.Path(self.temp.name) / 'paper.pdf'
        self.pdf.touch()
        self.window = dict(title=str(self.pdf), **{'class': 'org.pwmt.zathura'})
        self.properties = dict(filename=str(self.pdf), pagenumber=0, numberofpages=4)
        self.reference = dict(title='Paper title', attachments=[dict(path=str(self.pdf), file_type='pdf')])

    def test_physical_pages_are_one_based(self):
        self.assertEqual(validate(self.window, self.properties, self.reference)[1:], (1, 4))
        self.properties['pagenumber'] = 3
        self.assertEqual(validate(self.window, self.properties, self.reference)[1:], (4, 4))

    def test_same_basename_in_another_directory_is_rejected(self):
        other = self.pdf.parent / 'other' / self.pdf.name
        other.parent.mkdir(); other.touch()
        self.properties['filename'] = str(other)
        self.window['title'] = other.name
        with self.assertRaisesRegex(ValueError, 'does not match'):
            validate(self.window, self.properties, self.reference)

    def test_title_mismatch_is_rejected_even_with_correct_path(self):
        self.window['title'] = 'Another paper'
        with self.assertRaisesRegex(ValueError, 'title does not match'):
            validate(self.window, self.properties, self.reference)

    def test_supported_titles_and_symlink(self):
        link = self.pdf.parent / 'alias.pdf'; link.symlink_to(self.pdf)
        self.properties['filename'] = str(link)
        for title in (str(link), self.pdf.name, self.pdf.name + ' [1/4]', 'Paper title'):
            self.window['title'] = title
            self.assertEqual(validate(self.window, self.properties, self.reference)[0], str(self.pdf))

    def test_bad_page_and_non_zathura_window_are_rejected(self):
        for page in (-1, 4):
            self.properties['pagenumber'] = page
            with self.assertRaisesRegex(ValueError, 'valid PDF page'):
                validate(self.window, self.properties, self.reference)
        self.window['class'] = 'chromium'
        with self.assertRaisesRegex(ValueError, 'Focus the PDF'):
            validate(self.window, self.properties, self.reference)


if __name__ == '__main__':
    unittest.main()
