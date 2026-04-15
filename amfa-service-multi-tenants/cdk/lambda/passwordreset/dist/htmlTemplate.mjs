var h=(a,i,l,d,o,n)=>{let t=`<p>Your following MFA value${i.length>1?"s":""} has been changed${o?" by Admin":""}.</p>`;for(let e=0;e<i.length;e++)t+=`<p>&nbsp;&nbsp;&#x2022; ${i[e]} has been `,t+=l[e]&&l[e].length>1?"changed to "+l[e]:"removed",t+="</p>";return console.log("HTML template diff value",t),`
		<!DOCTYPE html >
			<html>
				<head>
					<meta charset="utf-8">
						<title>Email Title</title>
						<style>
							.container {
								width: 95%;
								box-shadow: 0 0.5em 1em 0 rgba(0,0,0,0.2);
								margin: 2em auto;
								border-radius: 0.5em;

							}
							.email {
								padding: 1em 4em;
							}
							.email-body {
								padding-top: 0.5em;
							}
							.email-footer {
								text-align: center;
							}
							.logo {
								text-align: center;
							}
							img {
								height: 57px;
								width: 313px;
							}
						</style>
				</head>
				<body>
					<div class="container">
						<div class="logo">
							<img src="${d}" alt="logo" />
						</div>
						<div class="email">
							<div>
								<h1>MFA value changed</h1>
							</div>
							<div class="email-body">
								<p>Hello ${a},</p>
								${t}
								<p>If you did not make this change, please contact the help desk.</p>
							</div>
							<div class="email-footer">
								<p>${n}</p>
							</div>
						</div>
					</div>
				</body>
			</html>
	`},m=h;export{m as default};
//# sourceMappingURL=htmlTemplate.mjs.map
