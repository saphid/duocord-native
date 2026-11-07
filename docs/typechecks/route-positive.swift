// Typechecked with the production Discord/Routes.swift, without test stubs.
func validRouteBoundaries() {
    _ = DiscordEndpoint.edit(ChannelID(1), MessageID(2))
    _ = DiscordEndpoint.guildMember(GuildID(3), UserID(4))
    _ = DiscordEndpoint.relationship(UserID(4), removing: false)
    _ = DiscordEndpoint.notificationSettings(GuildID(3))
}
