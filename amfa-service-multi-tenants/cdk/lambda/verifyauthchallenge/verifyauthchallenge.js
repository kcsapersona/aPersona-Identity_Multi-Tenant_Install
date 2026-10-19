exports.handler = async (event, context) => {
  console.log('entering verifyAuthChallenge');
  console.log('Received trigger:', event.triggerSource, 'pool:', event.userPoolId);

  event.response.answerCorrect = false;

  if (
    event.request.privateChallengeParameters.magicCode ==
      event.request.challengeAnswer ||
    event.request.privateChallengeParameters.answer ==
      event.request.challengeAnswer
  ) {
    event.response.answerCorrect = true;
  }

  context.done(null, event);
};
