exports.handler = async (event, context) => {
  console.log('entering verifyAuthChallenge');
  console.log('Received event:', JSON.stringify(event, null, 2));
  console.log('Received context:', JSON.stringify(context, null, 2));

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
