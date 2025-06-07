defmodule InterlinkedTest do
  use ExUnit.Case

  # inspired by https://programmersstone.blog/posts/scrappy-parsing/

  @tag :tmp_dir
  test "eh", %{tmp_dir: tmp_dir} do
    db1_path = Path.join(tmp_dir, "db1.sqlite")
    File.rm_rf!(db1_path)

    db1 = XQLite.open(db1_path, [:readwrite, :create])
    query(db1, "pragma journal_mode=wal")

    query(db1, """
    CREATE TABLE people (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      age INTEGER NOT NULL,
      email TEXT NOT NULL
    );
    """)

    query(db1, """
    CREATE UNIQUE INDEX person_email ON people(email);
    """)

    insert_all(
      db1,
      """
      INSERT INTO people (name, age, email) VALUES (?, ?, ?);
      """,
      [:text, :integer, :text],
      Enum.map(1..150, fn i ->
        ["Person #{i}", 20 + rem(i, 50), "person-#{i}@example.com"]
      end)
    )
  end

  defp query(db, sql, params \\ []) do
    stmt = XQLite.prepare(db, sql)

    try do
      bind_all(stmt, params, 1)
      XQLite.fetch_all(stmt)
    after
      XQLite.finalize(stmt)
    end
  end

  defp insert_all(db, sql, types, rows) do
    stmt = XQLite.prepare(db, sql)
    query(db, "begin immediate")

    try do
      XQLite.insert_all(stmt, types, rows)
    rescue
      e ->
        query(db, "rollback")
        reraise(e, __STACKTRACE__)
    else
      result ->
        query(db, "commit")
        result
    after
      XQLite.finalize(stmt)
    end
  end

  defp bind_all(stmt, [param | params], idx) do
    case param do
      i when is_integer(i) -> XQLite.bind_integer(stmt, idx, i)
      f when is_float(f) -> XQLite.bind_float(stmt, idx, f)
      t when is_binary(t) -> XQLite.bind_text(stmt, idx, t)
      nil -> XQLite.bind_null(stmt, idx)
    end

    bind_all(stmt, params, idx + 1)
  end

  defp bind_all(_stmt, [], _idx), do: :ok
end
