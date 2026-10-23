import MTPCore
import XCTest
@testable import FeatureDataTransfer

final class ExporterTests: XCTestCase {
    let result = QueryResult(
        columns: [
            ResultColumn(name: "id", typeName: "int8"),
            ResultColumn(name: "name", typeName: "text"),
            ResultColumn(name: "price", typeName: "numeric"),
            ResultColumn(name: "active", typeName: "bool"),
            ResultColumn(name: "meta", typeName: "jsonb"),
        ],
        rows: [
            ["1", "plain", "9.50", "t", "{\"b\": 1, \"a\": [true, null]}"],
            ["2", "comma, \"quoted\"\nnewline", "NaN", "f", nil],
            ["3", "", nil, nil, "not json"],
            ["4", "NULL", "-1e3", "t", "[]"],
        ])

    func testCSV() {
        let csv = DataExporter.render(result, format: .csv)
        XCTAssertEqual(csv, """
        id,name,price,active,meta
        1,plain,9.50,t,"{""b"": 1, ""a"": [true, null]}"
        2,"comma, ""quoted""
        newline",NaN,f,
        3,"",,,not json
        4,NULL,-1e3,t,[]

        """)
        // Round-trips through the importer's parser.
        let back = CSVParser.parse(csv)
        XCTAssertEqual(back.count, 5)
        XCTAssertEqual(back[2][1], "comma, \"quoted\"\nnewline")
        XCTAssertEqual(back[1][4], "{\"b\": 1, \"a\": [true, null]}")
    }

    func testCSVOptions() {
        var o = ExportOptions(delimiter: ";", includeHeader: false, nullStyle: .keyword, lineEnding: .crlf)
        var csv = DataExporter.render(result, format: .csv, options: o)
        XCTAssertEqual(csv.components(separatedBy: "\r\n"), [
            "1;plain;9.50;t;\"{\"\"b\"\": 1, \"\"a\"\": [true, null]}\"",
            "2;\"comma, \"\"quoted\"\"\nnewline\";NaN;f;NULL",
            "3;;NULL;NULL;not json",
            "4;\"NULL\";-1e3;t;[]",
            "",
        ])
        // A delimiter inside a value (or a header) forces quotes.
        o.delimiter = "|"
        o.includeHeader = true
        let r = QueryResult(columns: [ResultColumn(name: "a|b", typeName: "text")], rows: [["x|y"], ["z"]])
        csv = DataExporter.render(r, format: .csv, options: o)
        XCTAssertEqual(csv, "\"a|b\"\r\n\"x|y\"\r\nz\r\n")
    }

    func testTSV() {
        let tsv = DataExporter.render(result, format: .tsv)
        let lines = tsv.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "id\tname\tprice\tactive\tmeta")
        XCTAssertEqual(lines[1], "1\tplain\t9.50\tt\t\"{\"\"b\"\": 1, \"\"a\"\": [true, null]}\"")
        let parsed = CSVParser.parse(tsv, delimiter: "\t")
        XCTAssertEqual(parsed[2][1], "comma, \"quoted\"\nnewline")
        XCTAssertEqual(parsed[1][4], "{\"b\": 1, \"a\": [true, null]}")
        XCTAssertEqual(parsed[3], ["3", "", "", "", "not json"])
        // Commas never need quotes in TSV.
        let r = QueryResult(columns: [ResultColumn(name: "a", typeName: "text")], rows: [["x, y"], ["tab\there"]])
        XCTAssertEqual(DataExporter.render(r, format: .tsv), "a\nx, y\n\"tab\there\"\n")
    }

    func testJSON() throws {
        let json = DataExporter.render(result, format: .json, options: ExportOptions(prettyJSON: false))
        XCTAssertEqual(json, """
        [
        {"id":1,"name":"plain","price":9.50,"active":true,"meta":{"b":1,"a":[true,null]}},
        {"id":2,"name":"comma, \\"quoted\\"\\nnewline","price":"NaN","active":false,"meta":null},
        {"id":3,"name":"","price":null,"active":null,"meta":"not json"},
        {"id":4,"name":"NULL","price":-1e3,"active":true,"meta":[]}
        ]

        """)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 4)
        XCTAssertEqual(parsed?[0]["id"] as? Int, 1)
        XCTAssertEqual((parsed?[0]["meta"] as? [String: Any])?["b"] as? Int, 1)

        let pretty = DataExporter.render(result, format: .json)
        XCTAssertTrue(pretty.hasPrefix("[\n  {\n    \"id\": 1,\n    \"name\": \"plain\""), pretty)
        XCTAssertTrue(pretty.contains("\"meta\": {\n      \"b\": 1,\n      \"a\": [\n        true,\n        null\n      ]\n    }\n  },"), pretty)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(pretty.utf8)))

        let empty = DataExporter.render(QueryResult(columns: result.columns, rows: []), format: .json)
        XCTAssertEqual(empty, "[]\n")
    }

    func testJSONDuplicateColumnsAndControlChars() throws {
        let r = QueryResult(columns: [ResultColumn(name: "id", typeName: "int4"), ResultColumn(name: "id", typeName: "int4"),
                                      ResultColumn(name: "t", typeName: "text")],
                            rows: [["1", "2", "tab\there\u{01}\u{2028}"]])
        let line = DataExporter.render(r, format: .jsonLines)
        XCTAssertEqual(line, "{\"id\":1,\"id_2\":2,\"t\":\"tab\\there\\u0001\\u2028\"}\n")
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["t"] as? String, "tab\there\u{01}\u{2028}")
    }

    func testJSONLines() {
        let jl = DataExporter.render(result, format: .jsonLines)
        let lines = jl.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "{\"id\":1,\"name\":\"plain\",\"price\":9.50,\"active\":true,\"meta\":{\"b\":1,\"a\":[true,null]}}")
        for l in lines { XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(l.utf8))) }
    }

    func testSQLInsert() {
        let sql = DataExporter.render(result, format: .sqlInsert, options: ExportOptions(sqlBatchSize: 3), tableName: "public.Order Items")
        XCTAssertEqual(sql, """
        INSERT INTO public."Order Items" (id, name, price, active, meta) VALUES
          (1, 'plain', 9.50, TRUE, '{"b": 1, "a": [true, null]}'),
          (2, 'comma, "quoted"
        newline', 'NaN', FALSE, NULL),
          (3, '', NULL, NULL, 'not json');
        INSERT INTO public."Order Items" (id, name, price, active, meta) VALUES
          (4, 'NULL', -1e3, TRUE, '[]');

        """)
        let quotes = QueryResult(columns: [ResultColumn(name: "user", typeName: "text")], rows: [["O'Brien"], ["\\x"]])
        let one = DataExporter.render(quotes, format: .sqlInsert, options: ExportOptions(sqlBatchSize: 1), tableName: "t")
        XCTAssertEqual(one, "INSERT INTO t (\"user\") VALUES ('O''Brien');\nINSERT INTO t (\"user\") VALUES ('\\x');\n")
    }

    func testSQLiteInsertLiterals() {
        let r = QueryResult(columns: [ResultColumn(name: "flag", typeName: "BOOLEAN"), ResultColumn(name: "data", typeName: "BLOB"),
                                      ResultColumn(name: "n", typeName: "INTEGER")],
                            rows: [["1", "x'00ff'", "12"], ["false", "x'zz'", "abc"]])
        let sql = DataExporter.render(r, format: .sqlInsert, tableName: "main.t", dialect: SQLDialect(kind: .sqlite))
        XCTAssertEqual(sql, "INSERT INTO t (flag, data, n) VALUES\n  (1, x'00ff', 12),\n  (0, 'x''zz''', 'abc');\n")
    }

    func testMarkdown() {
        let md = DataExporter.render(result, format: .markdown)
        XCTAssertEqual(md, """
        | id | name | price | active | meta |
        | ---: | --- | ---: | --- | --- |
        | 1 | plain | 9.50 | t | {"b": 1, "a": [true, null]} |
        | 2 | comma, "quoted"<br>newline | NaN | f |  |
        | 3 |  |  |  | not json |
        | 4 | NULL | -1e3 | t | [] |

        """)
        let pipes = QueryResult(columns: [ResultColumn(name: "a|b", typeName: "text")], rows: [["x | y\r\nz"], [nil]])
        XCTAssertEqual(DataExporter.render(pipes, format: .markdown, options: ExportOptions(nullStyle: .keyword)),
                       "| a\\|b |\n| --- |\n| x \\| y<br>z |\n| NULL |\n")
    }

    func testLegacySignatureStillWorks() {
        let s = DataExporter.render(result, format: .csv, tableName: nil, dialect: SQLDialect(kind: .postgres))
        XCTAssertTrue(s.hasPrefix("id,name"))
    }

    func testStreamingMatchesRender() {
        for format in ExportFormat.allCases {
            let whole = DataExporter.render(result, format: format, tableName: "t")
            var e = ExportEncoder(format: format, columns: result.columns, tableName: "t")
            var streamed = e.header()
            streamed += e.encode(Array(result.rows.prefix(1)))
            streamed += e.encode(Array(result.rows.dropFirst()))
            streamed += e.footer()
            if format == .sqlInsert {
                // Pages split INSERT batches; both must still be valid statements.
                XCTAssertEqual(streamed.components(separatedBy: "INSERT INTO").count, 3)
            } else {
                XCTAssertEqual(streamed, whole, format.rawValue)
            }
        }
    }

    func testJSONTextRoundTrip() {
        let src = "{\"z\":1,\"a\":{\"k\":[1,2.50,-0.1e-2,\"\\u00e9\\ud83d\\ude00\"]},\"b\":false}"
        guard let v = JSONText.parse(src) else { return XCTFail("parse") }
        XCTAssertEqual(JSONText.string(v), "{\"z\":1,\"a\":{\"k\":[1,2.50,-0.1e-2,\"é😀\"]},\"b\":false}")
        XCTAssertNil(JSONText.parse("{\"a\":1,}"))
        XCTAssertNil(JSONText.parse("01"))
        XCTAssertNil(JSONText.parse("[1] x"))
        XCTAssertTrue(JSONText.isNumber("-12.5e+3"))
        XCTAssertFalse(JSONText.isNumber("1."))
        XCTAssertFalse(JSONText.isNumber("Infinity"))
    }
}
