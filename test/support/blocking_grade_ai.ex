defmodule CaptainHomework.BlockingGradeAI do
  def grade(exam) do
    send(Application.fetch_env!(:captain_homework, :grading_test_pid), {:grading_waiting, self()})

    receive do
      :finish_grading -> CaptainHomework.TestAI.grade(exam)
      :fail_grading -> {:error, "Correction indisponible"}
    end
  end
end
