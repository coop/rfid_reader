defmodule RFIDReader.Errors do
  defmodule RFIDReadInProgressError do
    defexception message: "Read in progress"
  end

  defmodule InvalidReadTimeoutError do
    defexception message: "The specified read_timeout needs to be 1s less than timeout"
  end

  defmodule ReadTimeoutError do
    defexception message: "The reader timed out reading results"
  end

  defmodule ReadError do
    defexception [:message]
  end
end
