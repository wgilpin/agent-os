defmodule AgentOS.SanitizerTest do
  use ExUnit.Case, async: true

  alias AgentOS.Sanitizer

  test "sanitize/2 preserves valid items" do
    item = %{
      "id" => "123",
      "author" => "elonmusk",
      "text" => "Tesla is doing great!",
      "urls" => ["https://tesla.com"]
    }

    assert {:ok, sanitized} = Sanitizer.sanitize(item)
    assert sanitized["id"] == "123"
    assert sanitized["author"] == "elonmusk"
    assert sanitized["text"] == "Tesla is doing great!"
    assert sanitized["urls"] == ["https://tesla.com"]
  end

  test "sanitize/2 rejects item with empty or missing id" do
    assert {:error, :invalid_id} = Sanitizer.sanitize(%{"author" => "a", "text" => "t"})

    assert {:error, :invalid_id} =
             Sanitizer.sanitize(%{"id" => "", "author" => "a", "text" => "t"})

    assert {:error, :invalid_id} =
             Sanitizer.sanitize(%{
               "id" => String.duplicate("a", 257),
               "author" => "a",
               "text" => "t"
             })
  end

  test "sanitize/2 rejects item with missing or too long author" do
    assert {:error, :invalid_author} = Sanitizer.sanitize(%{"id" => "1", "text" => "t"})

    assert {:error, :invalid_author} =
             Sanitizer.sanitize(%{
               "id" => "1",
               "author" => String.duplicate("a", 257),
               "text" => "t"
             })
  end

  test "sanitize/2 rejects item with missing or too long text" do
    assert {:error, :invalid_text} = Sanitizer.sanitize(%{"id" => "1", "author" => "a"})
    # Over 10,000 characters by default
    assert {:error, :invalid_text} =
             Sanitizer.sanitize(%{
               "id" => "1",
               "author" => "a",
               "text" => String.duplicate("a", 10_001)
             })
  end

  test "sanitize/2 strips control characters from text and normalizes UTF-8" do
    text = "Hello\u0000 World\u0007! \u0001"
    item = %{"id" => "1", "author" => "a", "text" => text}

    assert {:ok, sanitized} = Sanitizer.sanitize(item)
    assert sanitized["text"] == "Hello World! "
  end

  test "sanitize/2 rejects malformed or too many URLs" do
    valid_item = %{"id" => "1", "author" => "a", "text" => "t", "urls" => ["https://google.com"]}
    assert {:ok, _} = Sanitizer.sanitize(valid_item)

    invalid_url = %{"id" => "1", "author" => "a", "text" => "t", "urls" => ["not-a-url"]}
    assert {:error, :invalid_urls} = Sanitizer.sanitize(invalid_url)

    too_many_urls = %{
      "id" => "1",
      "author" => "a",
      "text" => "t",
      "urls" => Enum.map(1..33, fn _ -> "https://g.co" end)
    }

    assert {:error, :invalid_urls} = Sanitizer.sanitize(too_many_urls)
  end

  test "sanitize_list/2 filters out and logs invalid items" do
    items = [
      %{"id" => "1", "author" => "a", "text" => "valid text"},
      # missing text -> invalid
      %{"id" => "2", "author" => "a"},
      %{"id" => "3", "author" => "a", "text" => "another valid"}
    ]

    # Returns the list of sanitized items and the count of dropped items
    assert {sanitized_list, dropped_count} = Sanitizer.sanitize_list(items)
    assert length(sanitized_list) == 2
    assert dropped_count == 1
    assert Enum.map(sanitized_list, & &1["id"]) == ["1", "3"]
  end
end
