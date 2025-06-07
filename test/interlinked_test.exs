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

    assert query(db1, "select count(*) from sqlite_dbpage('main')") == [%{"count(*)" => 7}]

    assert query(db1, "pragma wal_checkpoint") == [
             %{
               "busy" => 0,
               "checkpointed" => 11,
               "log" => 11
             }
           ]

    info =
      File.open!(db1_path, [:read, :binary], fn fd ->
        header = parse_header(IO.binread(fd, 100))
        %{header: header}
      end)

    assert info == %{
             header: %{
               page_count: 7,
               page_size: 4096,
               application_id: 0,
               database_text_encoding: 1,
               default_page_cache_size: 0,
               file_change_counter: 2,
               first_freelist_trunk_page: 0,
               freelist_pages: 0,
               incremental_vacuum_mode: 0,
               largest_root_page_for_vacuum: 0,
               schema_cookie: 2,
               schema_format_number: 4,
               sqlite_version_number: 3_050_000,
               user_version: 0,
               version_valid_for_number: 2
             }
           }

    assert query(db1, "select data from sqlite_dbpage('main') where pgno = 1") == [
             %{"data" => File.open!(db1_path, [:read, :binary], &IO.binread(&1, 4096))}
           ]
  end

  defp query(db, sql, params \\ []) do
    stmt = XQLite.prepare(db, sql)
    columns = XQLite.column_names(stmt)

    try do
      bind_all(stmt, params, 1)
      XQLite.fetch_all(stmt)
    else
      rows ->
        Enum.map(rows, fn row ->
          Map.new(Enum.zip(columns, row))
        end)
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
      :done = result ->
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

  defp parse_header(bytes) do
    # https://www.sqlite.org/fileformat2.html#the_database_header
    <<
      # The header string: "SQLite format 3\000"
      "SQLite format 3\0"::bytes,
      # The database page size in bytes. Must be a power of two between 512 and 32768 inclusive, or the value 1 representing a page size of 65536.
      page_size::16-integer,
      # File format write version. 1 for legacy; 2 for WAL.
      2,
      # File format read version. 1 for legacy; 2 for WAL.
      2,
      # Bytes of unused "reserved" space at the end of each page. Usually 0.
      0,
      # Maximum embedded payload fraction. Must be 64.
      64,
      # Minimum embedded payload fraction. Must be 32.
      32,
      # Leaf payload fraction. Must be 32.
      32,
      # File change counter.
      file_change_counter::32,
      # Size of the database file in pages. The "in-header database size".
      page_count::32,
      # Page number of the first freelist trunk page.
      first_freelist_trunk_page::32,
      # Total number of freelist pages.
      freelist_pages::32,
      # The schema cookie.
      schema_cookie::32,
      # The schema format number. Supported schema formats are 1, 2, 3, and 4.
      schema_format_number::32,
      # Default page cache size.
      default_page_cache_size::32,
      # The page number of the largest root b-tree page when in auto-vacuum or incremental-vacuum modes, or zero otherwise.
      largest_root_page_for_vacuum::32,
      # The database text encoding. A value of 1 means UTF-8. A value of 2 means UTF-16le. A value of 3 means UTF-16be.
      database_text_encoding::32,
      # The "user version" as read and set by the user_version pragma.
      user_version::32,
      # True (non-zero) for incremental-vacuum mode. False (zero) otherwise.
      incremental_vacuum_mode::32,
      # The "Application ID" set by PRAGMA application_id.
      application_id::32,
      # Reserved for expansion. Must be zero.
      0::20*8,
      # The version-valid-for number.
      version_valid_for_number::32,
      # SQLITE_VERSION_NUMBER
      sqlite_version_number::32
    >> = bytes

    page_size =
      case page_size do
        1 -> 65_536
        _ -> page_size
      end

    %{
      page_size: page_size,
      file_change_counter: file_change_counter,
      page_count: page_count,
      first_freelist_trunk_page: first_freelist_trunk_page,
      freelist_pages: freelist_pages,
      schema_cookie: schema_cookie,
      schema_format_number: schema_format_number,
      default_page_cache_size: default_page_cache_size,
      largest_root_page_for_vacuum: largest_root_page_for_vacuum,
      database_text_encoding: database_text_encoding,
      user_version: user_version,
      incremental_vacuum_mode: incremental_vacuum_mode,
      application_id: application_id,
      version_valid_for_number: version_valid_for_number,
      sqlite_version_number: sqlite_version_number
    }
  end

  defp parse_page(bytes, i) do
    start = if i == 1, do: 100, else: 0

    <<
      # The one-byte flag at offset 0 indicating the b-tree page type.
      raw_type,
      # The two-byte integer at offset 1 gives the start of the first freeblock on the page, or is zero if there are no freeblocks.
      _first_page_freeblock::16,
      # The two-byte integer at offset 3 gives the number of cells on the page.
      cell_count::16,
      # The two-byte integer at offset 5 designates the start of the cell content area. A zero value for this integer is interpreted as 65536.
      _raw_cell_content_start::16,
      # The one-byte integer at offset 7 gives the number of fragmented free bytes within the cell content area.
      _fragmented_free_bytes,
      # The four-byte page number at offset 8 is the right-most pointer. This value appears in the header of interior b-tree pages only and is omitted from all other pages.
      right_most_pointer::32
    >> = binary_slice(bytes, start, 12)

    type =
      case raw_type do
        2 -> :interior_index
        5 -> :interior_table
        10 -> :leaf_index
        13 -> :leaf_table
      end

    %{
      index: i,
      start: start,
      type: type,
      cell_count: cell_count,
      right_most_pointer:
        if type in [:interior_index, :interior_table] do
          right_most_pointer
        end
    }
  end
end
