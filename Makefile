.PHONY: test test-global-queue test-pipeline-queue

test: test-global-queue test-pipeline-queue

test-global-queue:
	bash test/test_global_queue.sh

test-pipeline-queue:
	bash test/test_pipeline_queue.sh
