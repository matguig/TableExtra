import MTPCore
import XCTest
@testable import FeatureSchemaTools

final class TypeScriptGeneratorTests: XCTestCase {
    func assertLines(_ out: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        let lines = Set(out.lines())
        for e in expected where !lines.contains(e) {
            XCTFail("missing line: \(e)\n\(out)", file: file, line: line)
        }
    }

    func testNamingHelpers() {
        XCTAssertEqual(TypeScriptGenerator.pascalCase("order_items"), "OrderItems")
        XCTAssertEqual(TypeScriptGenerator.pascalCase("analytics.events"), "AnalyticsEvents")
        XCTAssertEqual(TypeScriptGenerator.pascalCase("2fa_codes"), "_2faCodes")
        XCTAssertEqual(TypeScriptGenerator.camelCase("unit_price"), "unitPrice")
        XCTAssertEqual(TypeScriptGenerator.camelCase("_private"), "_private")
        XCTAssertEqual(TypeScriptGenerator.propertyKey("analytics.events"), "\"analytics.events\"")
        XCTAssertEqual(TypeScriptGenerator.propertyKey("ok_name"), "ok_name")
    }

    func testKyselyOutputForFixtureSchema() {
        var tables = Fx.shop()
        tables.append(Fx.table("events", schema: "analytics", [
            Fx.col("id", "bigint", udt: "int8", nullable: false, identity: true),
            Fx.col("props", "jsonb"),
        ]))
        let out = TypeScriptGenerator.generate(tables: tables, enums: ["order_status": ["pending", "paid", "shipped", "cancelled"]])
        assertLines(out, [
            "import type { ColumnType } from \"kysely\";",
            "export type Timestamp = ColumnType<Date, Date | string, Date | string>;",
            "export type Int8 = ColumnType<string, bigint | number | string, bigint | number | string>;",
            "export type Numeric = ColumnType<string, number | string, number | string>;",
            "export type Json = ColumnType<JsonValue, string, string>;",
            "export type OrderStatus = \"cancelled\" | \"paid\" | \"pending\" | \"shipped\";",
            "export interface OrderItems {",
            "  order_id: Int8;",
            "  quantity: Generated<number>;",
            "  unit_price: Numeric;",
            "  status: Generated<OrderStatus>;",
            "  shipped_on: Timestamp | null;",
            "  tags: Generated<string[] | null>;",
            "  /** Login email */",
            "export interface AnalyticsEvents {",
            "  id: Generated<Int8>;",
            "  props: Json | null;",
            "export interface DB {",
            "  \"analytics.events\": AnalyticsEvents;",
            "  order_items: OrderItems;",
        ])
        XCTAssertTrue(out.contains("export type Generated<T> = T extends ColumnType<infer S, infer I, infer U>"))
        // DB keys sorted like kysely-codegen.
        let db = out.components(separatedBy: "export interface DB {")[1]
        XCTAssertLessThan(db.range(of: "\"analytics.events\"")!.lowerBound, db.range(of: "customers:")!.lowerBound)
    }

    func testPlainCamelCaseAndZod() {
        let opts = TypeScriptOptions(style: .interfaces, camelCase: true, zod: true)
        let out = TypeScriptGenerator.generate(tables: Fx.shop(), enums: [:], options: opts)
        XCTAssertFalse(out.contains("from \"kysely\""))
        XCTAssertFalse(out.contains("Generated<"))
        assertLines(out, [
            "import { z } from \"zod\";",
            "  unitPrice: string;",
            "  createdAt: Date;",
            "  orderId: string;",
            "  status: OrderStatus;",
            "export const orderStatusSchema = z.enum([\"pending\", \"paid\", \"shipped\", \"cancelled\"]);",
            "export const customersSchema = z.object({",
            "  fullName: z.string(),",
            "export const customersInsertSchema = z.object({",
            "  createdAt: z.union([z.date(), z.string()]).optional(),",
        ])
    }

    func testViewsCanBeExcluded() {
        var tables = Fx.shop()
        tables.append(Fx.table("customer_stats", kind: .view, [Fx.col("id", "bigint", udt: "int8")]))
        XCTAssertTrue(TypeScriptGenerator.generate(tables: tables, enums: [:]).contains("  customer_stats: CustomerStats;"))
        let noViews = TypeScriptGenerator.generate(tables: tables, enums: [:], options: TypeScriptOptions(includeViews: false))
        XCTAssertFalse(noViews.contains("CustomerStats"))
    }

    /// Snapshot-style check against the real test database.
    func testKyselyOutputForTestDatabase() async throws {
        let client = try TestDB.client()
        _ = try await client.connect()
        defer { client.close() }
        let i = Introspection.make(client)
        let pub = try await SchemaSnapshotLoader.load(client: client, introspector: i, schema: "public")
        let analytics = try await SchemaSnapshotLoader.load(client: client, introspector: i, schema: "analytics")
        let out = TypeScriptGenerator.generate(tables: pub.tables + analytics.tables, enums: pub.enumMap,
                                               options: TypeScriptOptions(domains: pub.domains))
        assertLines(out, [
            "import type { ColumnType } from \"kysely\";",
            "export type OrderStatus = \"cancelled\" | \"paid\" | \"pending\" | \"shipped\";",
            "export interface Customers {",
            "  id: Generated<Int8>;",
            "  email: string;",
            "  country: Generated<string | null>;",
            "  metadata: Generated<Json | null>;",
            "  created_at: Generated<Timestamp>;",
            "export interface OrderItems {",
            "  order_id: Int8;",
            "  product_id: number;",
            "  quantity: Generated<number>;",
            "  unit_price: Numeric;",
            "export interface Orders {",
            "  status: Generated<OrderStatus>;",
            "  total: Generated<Numeric>;",
            "  shipped_on: Timestamp | null;",
            "export interface Products {",
            "  tags: Generated<string[] | null>;",
            "  is_active: Generated<boolean>;",
            "export interface AuditLog {",
            "  payload: Json | null;",
            "export interface KyselyMigration {",
            "  name: string;",
            "export interface CustomerStats {",
            "export interface DailyRevenue {",
            "export interface AnalyticsEvents {",
            "export interface DB {",
            "  \"analytics.events\": AnalyticsEvents;",
            "  audit_log: AuditLog;",
            "  customer_stats: CustomerStats;",
            "  customers: Customers;",
            "  daily_revenue: DailyRevenue;",
            "  kysely_migration: KyselyMigration;",
            "  order_items: OrderItems;",
            "  orders: Orders;",
            "  products: Products;",
        ])
    }
}
