import MTPCore
import XCTest
@testable import FeatureDataTransfer

final class CSVParserTests: XCTestCase {
    func testBasicAndQuoting() {
        XCTAssertEqual(CSVParser.parse("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertEqual(CSVParser.parse("\"a,b\",\"he said \"\"hi\"\"\",c"), [["a,b", "he said \"hi\"", "c"]])
        XCTAssertEqual(CSVParser.parse("x,\"multi\nline\r\nvalue\",y\nz,,\n"), [["x", "multi\nline\r\nvalue", "y"], ["z", "", ""]])
        XCTAssertEqual(CSVParser.parse("a,b"), [["a", "b"]], "no trailing newline")
        XCTAssertEqual(CSVParser.parse("a,"), [["a", ""]], "trailing delimiter at EOF")
        XCTAssertEqual(CSVParser.parse("\"\""), [[""]])
        XCTAssertEqual(CSVParser.parse(""), [])
    }

    func testLineEndingsAndBlankLines() {
        XCTAssertEqual(CSVParser.parse("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVParser.parse("a,b\r1,2\r"), [["a", "b"], ["1", "2"]], "old Mac CR line endings")
        XCTAssertEqual(CSVParser.parse("a\n\n\nb\n\n"), [["a"], ["b"]], "blank lines are skipped")
        XCTAssertEqual(CSVParser.parse("\"x\"\r\n\"y\""), [["x"], ["y"]])
    }

    func testLenientMalformedInput() {
        XCTAssertEqual(CSVParser.parse("ab\"c,d"), [["ab\"c", "d"]], "stray quote in unquoted field")
        XCTAssertEqual(CSVParser.parse("\"abc\"def,g"), [["abcdef", "g"]], "text after closing quote")
        var p = CSVParser()
        var out: [CSVRecord] = []
        p.feed(Data("a,\"unterminated\nmore".utf8)) { out.append($0) }
        p.finish { out.append($0) }
        XCTAssertEqual(out.map(\.fields), [["a", "unterminated\nmore"]])
        XCTAssertTrue(p.hadUnterminatedQuote)
    }

    func testQuotedFlagsAndLineNumbers() {
        let recs = CSVParser.records(Data("h1,h2\n\"\",NULL\n\"multi\nline\",x\n\nlast,\"NULL\"\n".utf8))
        XCTAssertEqual(recs.map(\.line), [1, 2, 3, 6])
        XCTAssertEqual(recs[1].quoted, [true, false])
        XCTAssertEqual(recs[3].quoted, [false, true])
    }

    func testBOMAndChunkBoundaries() {
        let text = "\u{FEFF}name,city\n\"Zoë, \"\"Z\"\"\",Göteborg\nÅsa,\"multi\r\nline\"\n"
        let bytes = Array(text.utf8)
        let expected = [["name", "city"], ["Zoë, \"Z\"", "Göteborg"], ["Åsa", "multi\r\nline"]]
        // Every chunk size, including ones that split the BOM, CRLF, quotes and multi-byte characters.
        for size in 1...9 {
            var p = CSVParser()
            var out: [[String]] = []
            var i = 0
            while i < bytes.count {
                p.feed(bytes[i..<min(i + size, bytes.count)]) { out.append($0.fields) }
                i += size
            }
            p.finish { out.append($0.fields) }
            XCTAssertEqual(out, expected, "chunk size \(size)")
        }
    }

    func testOtherDelimitersAndLatin1() {
        XCTAssertEqual(CSVParser.parse("a;b;\"c;d\"\n", delimiter: ";"), [["a", "b", "c;d"]])
        XCTAssertEqual(CSVParser.parse("a\tb\t\n", delimiter: "\t"), [["a", "b", ""]])
        let latin = Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x31, 0x0A]) // "café,1" in ISO 8859-1
        XCTAssertEqual(CSVParser.records(latin, encoding: .latin1).map(\.fields), [["café", "1"]])
    }

    // MARK: Encoding

    func testEncodingDetection() {
        XCTAssertEqual(TextEncodingDetector.detect(Data([0xEF, 0xBB, 0xBF, 0x61])), DetectedEncoding(encoding: .utf8, bomLength: 3))
        XCTAssertEqual(TextEncodingDetector.detect(Data([0xFF, 0xFE, 0x61, 0x00])), DetectedEncoding(encoding: .utf16LE, bomLength: 2))
        XCTAssertEqual(TextEncodingDetector.detect(Data([0xFE, 0xFF, 0x00, 0x61])), DetectedEncoding(encoding: .utf16BE, bomLength: 2))
        XCTAssertEqual(TextEncodingDetector.detect(Data("plain ascii, é ü".utf8)).encoding, .utf8)
        XCTAssertEqual(TextEncodingDetector.detect(Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x31])).encoding, .latin1)
        // UTF-8 sample cut in the middle of a character is still UTF-8.
        let cut = Data(Array("abc é".utf8).dropLast())
        XCTAssertEqual(TextEncodingDetector.detect(cut).encoding, .utf8)
        // UTF-16 LE without BOM.
        let le = "id,name\n1,abc\n".data(using: .utf16LittleEndian)!
        XCTAssertEqual(TextEncodingDetector.detect(le), DetectedEncoding(encoding: .utf16LE, bomLength: 0))
    }

    func testUTF16FileReader() throws {
        let dir = try tempDir()
        let text = "id;name\n1;\"Zoë 😀\"\n2;Ünïcode\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let url = dir.appendingPathComponent("u16.csv")
        try data.write(to: url)
        let settings = try ImportFileLoader.sniff(url)
        XCTAssertEqual(settings.encoding, DetectedEncoding(encoding: .utf16LE, bomLength: 2))
        XCTAssertEqual(settings.delimiter, UInt8(ascii: ";"))
        XCTAssertTrue(settings.hasHeader)
        // Odd chunk sizes split code units and surrogate pairs.
        for chunk in [1, 3, 5, 7] {
            let reader = try DelimitedFileReader(url: url, encoding: settings.encoding, delimiter: settings.delimiter, chunkSize: chunk)
            var all: [[String]] = []
            while true {
                let batch = try reader.next(2)
                if batch.isEmpty { break }
                all += batch.map(\.fields)
            }
            XCTAssertEqual(all, [["id", "name"], ["1", "Zoë 😀"], ["2", "Ünïcode"]], "chunk \(chunk)")
        }
    }

    func testLatin1File() throws {
        let url = try tempDir().appendingPathComponent("latin.csv")
        try Data([0x6E, 0x6F, 0x6D, 0x0A, 0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url) // nom\ncafé\n
        let s = try ImportFileLoader.sniff(url)
        XCTAssertEqual(s.encoding.encoding, .latin1)
        let preview = try ImportFileLoader.preview(url, kind: .delimited, settings: s)
        XCTAssertEqual(preview.columns, ["nom"])
        XCTAssertEqual(preview.rows.first?.values, ["café"])
    }

    // MARK: Sniffing

    func testDelimiterDetection() {
        func detect(_ s: String) -> Character { Character(Unicode.Scalar(CSVSniffer.detectDelimiter(Array(s.utf8)))) }
        XCTAssertEqual(detect("a,b,c\n1,2,3\n"), ",")
        XCTAssertEqual(detect("price;qty\n1,5;2,5\n3,0;4\n"), ";", "European decimals")
        XCTAssertEqual(detect("a\tb\n\"x,y\"\tz\n"), "\t")
        XCTAssertEqual(detect("a|b|c\n1|2|3\n"), "|")
        XCTAssertEqual(detect("single\ncolumn\n"), ",")
        XCTAssertEqual(detect("name,notes\nann,\"likes; semicolons; a lot\"\nbob,\"x\"\n"), ",")
    }

    func testHeaderDetection() {
        XCTAssertTrue(CSVSniffer.detectHeader([["id", "amount"], ["1", "2.5"], ["2", "3"]]))
        XCTAssertFalse(CSVSniffer.detectHeader([["1", "2.5"], ["2", "3"]]))
        XCTAssertTrue(CSVSniffer.detectHeader([["name", "email"], ["Ann", "ann@x.io"], ["Bob", "bob@x.io"]]))
        XCTAssertFalse(CSVSniffer.detectHeader([["Ann", "Ann"], ["Bob", "bob@x.io"]]))
        XCTAssertTrue(CSVSniffer.detectHeader([["created", "flag"], ["2024-01-02", "true"]]))
        XCTAssertFalse(CSVSniffer.detectHeader([["2024-01-01", "x"], ["2024-01-02", "y"]]))
    }

    // MARK: Types

    func testTypeInference() {
        XCTAssertEqual(TypeInference.infer(["1", "-2", "+3", nil, ""]), .integer)
        XCTAssertEqual(TypeInference.infer(["1", "3000000000"]), .bigint)
        XCTAssertEqual(TypeInference.infer(["1", "99999999999999999999999"]), .numeric)
        XCTAssertEqual(TypeInference.infer(["1", "2.5", ".5", "1e3"]), .numeric)
        XCTAssertEqual(TypeInference.infer(["00123", "1"]), .text, "leading zeros are identifiers")
        XCTAssertEqual(TypeInference.infer(["true", "FALSE", "t", "no"]), .boolean)
        XCTAssertEqual(TypeInference.infer(["1", "0"]), .integer)
        XCTAssertEqual(TypeInference.infer(["2024-01-31", "1999-12-01"]), .date)
        XCTAssertEqual(TypeInference.infer(["2024-13-01"]), .text)
        XCTAssertEqual(TypeInference.infer(["2024-01-31", "2024-01-31 10:00:00"]), .timestamp)
        XCTAssertEqual(TypeInference.infer(["2024-01-31T10:00:00.123Z", "2024-01-31 10:00+02:00"]), .timestamptz)
        XCTAssertEqual(TypeInference.infer(["2024-01-31 10:00:00-05"]), .timestamptz)
        XCTAssertEqual(TypeInference.infer(["6f1c3a8e-5d2b-4e4a-9a51-0e8b1d5c9f00"]), .uuid)
        XCTAssertEqual(TypeInference.infer(["{\"a\": 1}", "[1,2]"]), .json)
        XCTAssertEqual(TypeInference.infer(["{not json}"]), .text)
        XCTAssertEqual(TypeInference.infer(["1", "abc"]), .text)
        XCTAssertEqual(TypeInference.infer([nil, ""]), .text)

        let pg = SQLDialect(kind: .postgres), lite = SQLDialect(kind: .sqlite)
        XCTAssertEqual(InferredType.json.sqlType(for: pg), "jsonb")
        XCTAssertEqual(InferredType.timestamptz.sqlType(for: pg), "timestamptz")
        XCTAssertEqual(InferredType.bigint.sqlType(for: lite), "INTEGER")
        XCTAssertFalse(TypeInference.isCompatible(.text, with: .integer))
        XCTAssertTrue(TypeInference.isCompatible(.integer, with: .decimal))
        XCTAssertEqual(TypeInference.columnNames(from: ["id", "", "Id", " name "]), ["id", "column_2", "Id_2", "name"])
    }

    func testJSONSource() throws {
        let url = try tempDir().appendingPathComponent("rows.json")
        try Data("""
        [{"id": 1, "name": "a", "tags": ["x"], "ok": true},
         {"name": "b", "id": 2, "extra": null, "ok": false, "n": 1.50}]
        """.utf8).write(to: url)
        XCTAssertEqual(ImportFileLoader.kind(of: url), .json)
        let p = try ImportFileLoader.preview(url, kind: .json, settings: ImportFileSettings())
        XCTAssertEqual(p.columns, ["id", "name", "tags", "ok", "extra", "n"])
        XCTAssertEqual(p.rows[0].values, ["1", "a", "[\"x\"]", "true", nil, nil])
        XCTAssertEqual(p.rows[1].values, ["2", "b", nil, "false", nil, "1.50"])
        XCTAssertEqual(p.inferredTypes, [.integer, .text, .json, .boolean, .text, .numeric])

        let lines = try tempDir().appendingPathComponent("rows.ndjson")
        try Data("{\"a\":1}\n\n{\"a\":2,\"b\":\"x\"}\n".utf8).write(to: lines)
        let q = try ImportFileLoader.preview(lines, kind: .json, settings: ImportFileSettings())
        XCTAssertEqual(q.columns, ["a", "b"])
        XCTAssertEqual(q.rows.count, 2)
    }
}
