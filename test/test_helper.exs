# Start each test run from a clean persistence dir so DETS state from a
# previous run never leaks into tests.
File.rm_rf!(Application.get_env(:siano, :data_dir, "tmp/siano_test_data"))

ExUnit.start()
