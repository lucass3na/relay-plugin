import { describe, it, expect, beforeEach } from "vitest";
import { OrderService } from "./order-service";

describe("OrderService", () => {
  let db: FakeDatabase;
  let service: OrderService;

  beforeEach(() => {
    db = new FakeDatabase();
    service = new OrderService(db);
  });

  it("finds an order by id", async () => {
    db.seed("order-1", { id: "order-1", total: 42 });
    const order = await service.findById("order-1");
    expect(order).toEqual({ id: "order-1", total: 42 });
  });

  it("returns null for a missing order", async () => {
    const order = await service.findById("missing");
    expect(order).toBeNull();
  });

  it("creates a new order", async () => {
    const order = await service.create(42);
    expect(order.total).toBe(42);
    expect(order.id).toBeDefined();
  });

  it("deletes an order", async () => {
    db.seed("order-1", { id: "order-1", total: 42 });
    await service.delete("order-1");
    expect(await service.findById("order-1")).toBeNull();
  });
});

class FakeDatabase {
  private rows = new Map<string, Record<string, unknown>>();
  seed(id: string, row: Record<string, unknown>) {
    this.rows.set(id, row);
  }
  async query(sql: string, params: unknown[]) {
    return this.rows.get(params[0] as string) ?? null;
  }
}
