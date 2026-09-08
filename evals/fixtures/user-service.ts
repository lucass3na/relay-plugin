export interface User {
  id: string;
  email: string;
  displayName: string;
  createdAt: Date;
}

export class UserService {
  constructor(private readonly db: Database) {}

  async findById(id: string): Promise<User | null> {
    const row = await this.db.query("SELECT * FROM users WHERE id = ?", [id]);
    return row ? this.toUser(row) : null;
  }

  async findByEmail(email: string): Promise<User | null> {
    const row = await this.db.query("SELECT * FROM users WHERE email = ?", [email]);
    return row ? this.toUser(row) : null;
  }

  async create(email: string, displayName: string): Promise<User> {
    const id = crypto.randomUUID();
    await this.db.query(
      "INSERT INTO users (id, email, display_name, created_at) VALUES (?, ?, ?, ?)",
      [id, email, displayName, new Date()],
    );
    return { id, email, displayName, createdAt: new Date() };
  }

  async delete(id: string): Promise<void> {
    await this.db.query("DELETE FROM users WHERE id = ?", [id]);
  }

  private toUser(row: Record<string, unknown>): User {
    return {
      id: row.id as string,
      email: row.email as string,
      displayName: row.display_name as string,
      createdAt: new Date(row.created_at as string),
    };
  }
}

interface Database {
  query(sql: string, params: unknown[]): Promise<Record<string, unknown>>;
}
