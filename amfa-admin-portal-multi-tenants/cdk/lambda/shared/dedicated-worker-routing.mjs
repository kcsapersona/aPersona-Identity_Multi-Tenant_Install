const DEDICATED_WORKER_ARN =
  /^arn:aws:lambda:[a-z0-9-]+:\d{12}:function:ad-sync-worker-tenant-/;

export function isDedicatedWorkerArn(value) {
  return typeof value === 'string' && DEDICATED_WORKER_ARN.test(value);
}

export function selectAdSyncWorker(state, sharedWorker) {
  const dedicatedLambdaArn = state?.dedicatedLambdaArn;
  if (state?.mode !== 'dedicated' || !dedicatedLambdaArn) return sharedWorker;
  return isDedicatedWorkerArn(dedicatedLambdaArn)
    ? dedicatedLambdaArn
    : sharedWorker;
}
