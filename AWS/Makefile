help:
	cat Makefile

ecs-stop-task:
	aws ecs stop-task --profile ${AWS_PROFILE} --cluster zig-zag-zoe --task ${TASK_ID}

ecs-start-task:
	aws ecs run-task --profile ${AWS_PROFILE} --cluster zig-zag-zoe --task-definition zig-zag-zoe-task

ecs-restart: ecs-stop-task ecs-start-task
